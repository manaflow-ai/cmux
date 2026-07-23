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
    private let isRunningInBackground: () -> Bool
    private let onContinueInBackground: (UUID, UUID) -> Void
    private let canViewComputerUse: (ComputerUseTargetIdentity) -> Bool
    private let onViewComputerUse: (ComputerUseTargetIdentity) -> Void
    private let onNoLiveSessions: () -> Void
    private var snapshotCancellable: AnyCancellable?
    private var currentSnapshot = ComputerUseMenuBarSnapshot.hidden
    private var hasRenderedSnapshot = false
    private var isMenuOpen = false
    private var backgroundActions: [ObjectIdentifier: () -> Void] = [:]
    private var viewActions: [ObjectIdentifier: () -> Void] = [:]

    init(
        snapshotStore: ComputerUseMenuBarSnapshotStore,
        isRunningInBackground: @escaping () -> Bool,
        onContinueInBackground: @escaping (UUID, UUID) -> Void,
        canViewComputerUse: @escaping (ComputerUseTargetIdentity) -> Bool,
        onViewComputerUse: @escaping (ComputerUseTargetIdentity) -> Void,
        onNoLiveSessions: @escaping () -> Void
    ) {
        self.snapshotStore = snapshotStore
        self.isRunningInBackground = isRunningInBackground
        self.onContinueInBackground = onContinueInBackground
        self.canViewComputerUse = canViewComputerUse
        self.onViewComputerUse = onViewComputerUse
        self.onNoLiveSessions = onNoLiveSessions
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
        let hadLiveSession = !currentSnapshot.rows.isEmpty
        currentSnapshot = snapshot
        hasRenderedSnapshot = true
        if hadLiveSession, snapshot.rows.isEmpty {
            onNoLiveSessions()
        }
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

        let runningInBackground = isRunningInBackground()
        let viewTitle = String(localized: "computerUse.menu.viewComputerUse", defaultValue: "View Computer Use")
        let viewItem = NSMenuItem(
            title: viewTitle,
            action: #selector(viewComputerUseAction(_:)),
            keyEquivalent: ""
        )
        viewItem.target = self
        viewItem.image = NSImage(systemSymbolName: "eye", accessibilityDescription: viewTitle)
        if let identity = row.targetIdentity, canViewComputerUse(identity) {
            viewActions[ObjectIdentifier(viewItem)] = { [onViewComputerUse] in
                onViewComputerUse(identity)
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
        backgroundActions[ObjectIdentifier(backgroundItem)] = { [onContinueInBackground] in
            onContinueInBackground(row.workspaceID, row.surfaceID)
        }
        menu.addItem(backgroundItem)
    }

    private func updateStatusItemAccessibility() {
        let label = isRunningInBackground()
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
