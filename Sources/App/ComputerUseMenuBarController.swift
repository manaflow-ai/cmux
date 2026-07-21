import AppKit
import Combine
import Darwin
import Foundation

/// Owns the dedicated computer-use status item and renders value-only session snapshots.
@MainActor
final class ComputerUseMenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu(title: String(localized: "computerUse.menu.title", defaultValue: "Computer Use"))
    private let snapshotStore: ComputerUseMenuBarSnapshotStore
    private let isRunningInBackground: () -> Bool
    private let onContinueInBackground: (UUID, UUID) -> Void
    private let canViewComputerUse: (ComputerUseTargetIdentity) -> Bool
    private let onViewComputerUse: (ComputerUseTargetIdentity) -> Void
    private let onNoLiveSessions: () -> Void
    private var snapshotCancellable: AnyCancellable?
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
                systemSymbolName: "cursorarrow.rays",
                accessibilityDescription: String(localized: "computerUse.menu.title", defaultValue: "Computer Use")
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
        rebuildMenu(rows: snapshotStore.snapshot.rows)
        snapshotStore.refresh()
    }

    func removeFromMenuBar() {
        snapshotCancellable?.cancel()
        snapshotCancellable = nil
        snapshotStore.stop()
        statusItem.menu = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func refreshUI(snapshot: ComputerUseMenuBarSnapshot) {
        if snapshot.rows.isEmpty {
            onNoLiveSessions()
        }
        statusItem.isVisible = snapshot.shouldShowStatusItem
        updateStatusItemAccessibility()
        rebuildMenu(rows: snapshot.rows)
    }

    private func rebuildMenu(rows: [ComputerUseMenuBarRow]) {
        menu.removeAllItems()
        backgroundActions.removeAll(keepingCapacity: true)
        viewActions.removeAll(keepingCapacity: true)

        guard !rows.isEmpty else {
            let item = NSMenuItem(
                title: String(localized: "computerUse.menu.noLiveSessions", defaultValue: "No live agent sessions"),
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        let runningInBackground = isRunningInBackground()
        for row in rows {
            let sessionItem = NSMenuItem(title: row.title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: row.title)

            let viewItem = NSMenuItem(
                title: String(localized: "computerUse.menu.viewComputerUse", defaultValue: "View Computer Use"),
                action: #selector(viewComputerUseAction(_:)),
                keyEquivalent: ""
            )
            viewItem.target = self
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
            submenu.addItem(viewItem)

            let backgroundItem = NSMenuItem(
                title: String(
                    localized: "computerUse.menu.continueInBackground",
                    defaultValue: "Continue in Background"
                ),
                action: #selector(continueInBackgroundAction(_:)),
                keyEquivalent: ""
            )
            backgroundItem.target = self
            backgroundItem.state = runningInBackground ? .on : .off
            backgroundActions[ObjectIdentifier(backgroundItem)] = { [onContinueInBackground] in
                onContinueInBackground(row.workspaceID, row.surfaceID)
            }
            submenu.addItem(backgroundItem)

            sessionItem.submenu = submenu
            menu.addItem(sessionItem)
        }
    }

    private func updateStatusItemAccessibility() {
        let label = isRunningInBackground()
            ? String(
                localized: "computerUse.menu.backgroundStatus",
                defaultValue: "Computer Use — Running in Background"
            )
            : String(localized: "computerUse.menu.title", defaultValue: "Computer Use")
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
