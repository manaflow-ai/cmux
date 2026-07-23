import AppKit
import Combine
import Darwin
import Foundation

/// Owns the dedicated computer-use status item and renders value-only session snapshots.
@MainActor
final class ComputerUseMenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu(title: String(localized: "computerUse.menu.title", defaultValue: "cmux Computer Use"))
    private let snapshotStore: ComputerUseMenuBarSnapshotStore
    private let isRunningInBackground: (String, String) -> Bool
    private let onContinueInBackground:
        (UUID, UUID, String, String, AgentPIDProcessIdentity) -> Bool
    private let canViewComputerUse:
        (ComputerUseTargetIdentity, String, String, AgentPIDProcessIdentity) -> Bool
    private let onViewComputerUse:
        (ComputerUseTargetIdentity, String, String, AgentPIDProcessIdentity) -> Bool
    private var snapshotCancellable: AnyCancellable?
    private var currentSnapshot = ComputerUseMenuBarSnapshot.hidden
    private var hasRenderedSnapshot = false
    private var isMenuOpen = false
    private var backgroundActions: [ObjectIdentifier: () -> Void] = [:]
    private var viewActions: [ObjectIdentifier: () -> Void] = [:]

    init(
        snapshotStore: ComputerUseMenuBarSnapshotStore,
        isRunningInBackground: @escaping (String, String) -> Bool,
        onContinueInBackground:
            @escaping (UUID, UUID, String, String, AgentPIDProcessIdentity) -> Bool,
        canViewComputerUse:
            @escaping (ComputerUseTargetIdentity, String, String, AgentPIDProcessIdentity) -> Bool,
        onViewComputerUse:
            @escaping (ComputerUseTargetIdentity, String, String, AgentPIDProcessIdentity) -> Bool
    ) {
        self.snapshotStore = snapshotStore
        self.isRunningInBackground = isRunningInBackground
        self.onContinueInBackground = onContinueInBackground
        self.canViewComputerUse = canViewComputerUse
        self.onViewComputerUse = onViewComputerUse
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "cursorarrow.motionlines",
                accessibilityDescription: String(localized: "computerUse.menu.title", defaultValue: "cmux Computer Use")
            )
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
        }
        updateStatusItemAccessibility()

        snapshotCancellable = snapshotStore.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                Task { @MainActor in self?.refreshUI(snapshot: snapshot) }
            }
        snapshotStore.start()
        refreshUI(snapshot: snapshotStore.snapshot)
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        rebuildMenu(rows: currentSnapshot.rows)
        snapshotStore.refresh()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    func removeFromMenuBar() {
        snapshotCancellable?.cancel()
        snapshotCancellable = nil
        snapshotStore.stop()
        statusItem.menu = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func refreshUI(snapshot: ComputerUseMenuBarSnapshot) {
        guard !hasRenderedSnapshot || snapshot != currentSnapshot else { return }
        currentSnapshot = snapshot
        hasRenderedSnapshot = true
        statusItem.isVisible = snapshot.shouldShowStatusItem
        updateStatusItemAccessibility()

        // State files can update several times per second. The menu only needs
        // rebuilding while it is visible; the next open always uses the latest
        // immutable snapshot. This keeps AppKit menu churn off the typing path.
        if isMenuOpen {
            rebuildMenu(rows: snapshot.rows)
        }
    }

    private func rebuildMenu(rows: [ComputerUseMenuBarRow]) {
        menu.removeAllItems()
        backgroundActions.removeAll(keepingCapacity: true)
        viewActions.removeAll(keepingCapacity: true)

        guard let row = rows.first else {
            let item = NSMenuItem(
                title: String(localized: "computerUse.menu.noLiveSessions", defaultValue: "No live agent sessions"),
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        let sessionItem = NSMenuItem(title: row.title, action: nil, keyEquivalent: "")
        sessionItem.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: row.title)
        sessionItem.isEnabled = false
        menu.addItem(sessionItem)
        menu.addItem(NSMenuItem.separator())

        let driverSessionID = ComputerUseSessionScope.driverSessionID(
            surfaceID: row.surfaceID
        )
        let runningInBackground = isRunningInBackground(
            driverSessionID,
            row.id
        )
        let viewTitle = String(localized: "computerUse.menu.viewComputerUse", defaultValue: "View Computer Use")
        let viewItem = NSMenuItem(
            title: viewTitle,
            action: #selector(viewComputerUseAction(_:)),
            keyEquivalent: ""
        )
        viewItem.target = self
        viewItem.image = NSImage(systemSymbolName: "eye", accessibilityDescription: viewTitle)
        if
            let identity = row.targetIdentity,
            let stateWriterIdentity = row.stateWriterIdentity,
            canViewComputerUse(
                identity,
                driverSessionID,
                row.id,
                stateWriterIdentity
            )
        {
            viewActions[ObjectIdentifier(viewItem)] = { [onViewComputerUse] in
                _ = onViewComputerUse(
                    identity,
                    driverSessionID,
                    row.id,
                    stateWriterIdentity
                )
            }
            viewItem.state = runningInBackground ? .off : .on
        } else {
            viewItem.isEnabled = false
            viewItem.toolTip = String(
                localized: "computerUse.menu.noActivityTooltip",
                defaultValue: "No computer-use activity yet"
            )
        }
        menu.addItem(viewItem)

        let backgroundTitle = String(
            localized: "computerUse.menu.continueInBackground",
            defaultValue: "Continue in Background"
        )
        let backgroundItem = NSMenuItem(
            title: backgroundTitle,
            action: #selector(continueInBackgroundAction(_:)),
            keyEquivalent: ""
        )
        backgroundItem.target = self
        backgroundItem.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: backgroundTitle)
        backgroundItem.state = runningInBackground ? .on : .off
        if let stateWriterIdentity = row.stateWriterIdentity {
            backgroundActions[ObjectIdentifier(backgroundItem)] = {
                [onContinueInBackground] in
                _ = onContinueInBackground(
                    row.workspaceID,
                    row.surfaceID,
                    driverSessionID,
                    row.id,
                    stateWriterIdentity
                )
            }
        } else {
            backgroundItem.isEnabled = false
        }
        menu.addItem(backgroundItem)
    }

    private func updateStatusItemAccessibility() {
        let activeSession = currentSnapshot.rows.first.map {
            (
                driverSessionID: ComputerUseSessionScope.driverSessionID(
                    surfaceID: $0.surfaceID
                ),
                logicalSessionID: $0.id
            )
        }
        let label = activeSession.map {
            isRunningInBackground(
                $0.driverSessionID,
                $0.logicalSessionID
            )
        } == true
            ? String(
                localized: "computerUse.menu.backgroundStatus",
                defaultValue: "cmux Computer Use — Running in Background"
            )
            : String(localized: "computerUse.menu.title", defaultValue: "cmux Computer Use")
        statusItem.button?.toolTip = label
        statusItem.button?.setAccessibilityLabel(label)
    }

    @objc private func continueInBackgroundAction(_ sender: NSMenuItem) {
        backgroundActions[ObjectIdentifier(sender)]?()
        updateStatusItemAccessibility()
    }

    @objc private func viewComputerUseAction(_ sender: NSMenuItem) {
        viewActions[ObjectIdentifier(sender)]?()
        updateStatusItemAccessibility()
    }
}
