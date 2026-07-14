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
    private let onFocusTerminal: (UUID, UUID) -> Void
    private let canFocusTarget: (ComputerUseTargetIdentity) -> Bool
    private let onFocusTarget: (ComputerUseTargetIdentity) -> Void
    private var snapshotCancellable: AnyCancellable?
    private var terminalActions: [ObjectIdentifier: () -> Void] = [:]
    private var targetActions: [ObjectIdentifier: () -> Void] = [:]

    init(
        snapshotStore: ComputerUseMenuBarSnapshotStore,
        onFocusTerminal: @escaping (UUID, UUID) -> Void,
        canFocusTarget: @escaping (ComputerUseTargetIdentity) -> Bool,
        onFocusTarget: @escaping (ComputerUseTargetIdentity) -> Void
    ) {
        self.snapshotStore = snapshotStore
        self.onFocusTerminal = onFocusTerminal
        self.canFocusTarget = canFocusTarget
        self.onFocusTarget = onFocusTarget
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        if let button = statusItem.button {
            let label = String(localized: "computerUse.menu.title", defaultValue: "Computer Use")
            let image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: label)
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = label
            button.setAccessibilityLabel(label)
        }

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
        statusItem.isVisible = snapshot.shouldShowStatusItem
        rebuildMenu(rows: snapshot.rows)
    }

    private func rebuildMenu(rows: [ComputerUseMenuBarRow]) {
        menu.removeAllItems()
        terminalActions.removeAll(keepingCapacity: true)
        targetActions.removeAll(keepingCapacity: true)

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

        for row in rows {
            let sessionItem = NSMenuItem(title: row.title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: row.title)

            let terminalItem = NSMenuItem(
                title: String(localized: "computerUse.menu.focusTerminal", defaultValue: "Focus Terminal"),
                action: #selector(focusTerminalAction(_:)),
                keyEquivalent: ""
            )
            terminalItem.target = self
            terminalActions[ObjectIdentifier(terminalItem)] = { [onFocusTerminal] in
                onFocusTerminal(row.workspaceID, row.surfaceID)
            }
            submenu.addItem(terminalItem)

            let targetItem = NSMenuItem(
                title: String(localized: "computerUse.menu.focusTarget", defaultValue: "Focus Computer-Use Target"),
                action: #selector(focusTargetAction(_:)),
                keyEquivalent: ""
            )
            targetItem.target = self
            if let identity = row.targetIdentity, canFocusTarget(identity) {
                targetActions[ObjectIdentifier(targetItem)] = { [onFocusTarget] in
                    onFocusTarget(identity)
                }
            } else {
                targetItem.isEnabled = false
                targetItem.toolTip = String(
                    localized: "computerUse.menu.noActivityTooltip",
                    defaultValue: "No computer-use activity yet"
                )
            }
            submenu.addItem(targetItem)
            sessionItem.submenu = submenu
            menu.addItem(sessionItem)
        }
    }

    @objc private func focusTerminalAction(_ sender: NSMenuItem) {
        terminalActions[ObjectIdentifier(sender)]?()
    }

    @objc private func focusTargetAction(_ sender: NSMenuItem) {
        targetActions[ObjectIdentifier(sender)]?()
    }
}
