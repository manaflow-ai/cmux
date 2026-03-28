import AppKit
import Combine
import SwiftUI

@MainActor
final class WindowToolbarController: NSObject, NSToolbarDelegate {
    private let commandItemIdentifier = NSToolbarItem.Identifier("cmux.focusedCommand")

    private weak var tabManager: TabManager?

    private var commandLabels: [ObjectIdentifier: NSTextField] = [:]
    private var observers: [NSObjectProtocol] = []
    private let focusedCommandUpdateCoalescer = NotificationBurstCoalescer(delay: 1.0 / 30.0)
    private var lastKnownPresentationMode: WorkspacePresentationModeSettings.Mode = WorkspacePresentationModeSettings.mode()

    override init() {
        super.init()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func start(tabManager: TabManager) {
        self.tabManager = tabManager
        attachToExistingWindows()
        installObservers()
        scheduleFocusedCommandTextUpdate()
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .ghosttyDidSetTitle,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleFocusedCommandTextUpdate()
            }
        })

        observers.append(center.addObserver(
            forName: .ghosttyDidFocusTab,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleFocusedCommandTextUpdate()
            }
        })

        observers.append(center.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            Task { @MainActor in
                self?.attach(to: window)
            }
        })

        observers.append(center.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateToolbarVisibilityIfNeeded()
            }
        })
    }

    private func updateToolbarVisibilityIfNeeded() {
        let currentMode = WorkspacePresentationModeSettings.mode()
        guard currentMode != lastKnownPresentationMode else { return }
        lastKnownPresentationMode = currentMode
        let isMinimal = currentMode == .minimal
        for window in NSApp.windows {
            if isMinimal {
                window.toolbar = nil
            } else {
                attach(to: window)
            }
        }
        // After toolbar changes, force titlebar accessories to recalculate.
        // Toolbar removal/re-addition changes the titlebar geometry, and
        // accessories hidden via isHidden need a layout pass to reappear.
        if !isMinimal {
            DispatchQueue.main.async {
                for window in NSApp.windows {
                    for accessory in window.titlebarAccessoryViewControllers {
                        if !accessory.isHidden {
                            accessory.view.needsLayout = true
                            accessory.view.superview?.needsLayout = true
                        }
                    }
                    window.contentView?.needsLayout = true
                    window.contentView?.superview?.needsLayout = true
                    window.invalidateShadow()
                }
            }
        }
    }

    private func attachToExistingWindows() {
        for window in NSApp.windows {
            attach(to: window)
        }
    }

    private func attach(to window: NSWindow) {
        guard window.toolbar == nil else { return }
        guard !WorkspacePresentationModeSettings.isMinimal() else { return }
        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("cmux.toolbar"))
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.sizeMode = .small
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        window.titleVisibility = .hidden
    }

    private func scheduleFocusedCommandTextUpdate() {
        focusedCommandUpdateCoalescer.signal { [weak self] in
            self?.updateFocusedCommandText()
        }
    }

    private func updateFocusedCommandText() {
        guard let tabManager else { return }
        let text: String
        if let selectedId = tabManager.selectedTabId,
           let tab = tabManager.tabs.first(where: { $0.id == selectedId }) {
            let title = tab.title.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            text = title.isEmpty ? "Cmd: —" : "Cmd: \(title)"
        } else {
            text = "Cmd: —"
        }

        for label in commandLabels.values {
            if label.stringValue != text {
                label.stringValue = text
            }
        }
    }

    // MARK: - NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [commandItemIdentifier, .flexibleSpace]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [commandItemIdentifier, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemIdentifier == commandItemIdentifier {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let label = NSTextField(labelWithString: "Cmd: —")
            label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            item.view = label
            commandLabels[ObjectIdentifier(toolbar)] = label
            scheduleFocusedCommandTextUpdate()
            return item
        }


        return nil
    }

}
