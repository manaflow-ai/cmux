import AppKit
import Combine
import SwiftUI

final class WindowToolbarController: NSObject, NSToolbarDelegate {
    private let commandItemIdentifier = NSToolbarItem.Identifier("cmux.focusedCommand")
    private let updateItemIdentifier = NSToolbarItem.Identifier("cmux.updatePill")

    private weak var tabManager: TabManager?
    private weak var updateViewModel: UpdateViewModel?

    private var commandLabels: [ObjectIdentifier: NSTextField] = [:]
    private var observers: [NSObjectProtocol] = []
    private var updateCancellables: [ObjectIdentifier: AnyCancellable] = [:]
    private var updateHostingViews: [ObjectIdentifier: NSView] = [:]

    init(updateViewModel: UpdateViewModel) {
        self.updateViewModel = updateViewModel
        super.init()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        for cancellable in updateCancellables.values {
            cancellable.cancel()
        }
    }

    func start(tabManager: TabManager) {
        self.tabManager = tabManager
        attachToExistingWindows()
        installObservers()
        updateFocusedCommandText()
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .ghosttyDidSetTitle,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateFocusedCommandText()
        })

        observers.append(center.addObserver(
            forName: .ghosttyDidFocusTab,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateFocusedCommandText()
        })

        observers.append(center.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            self?.attach(to: window)
        })
    }

    private func attachToExistingWindows() {
        for window in NSApp.windows {
            attach(to: window)
        }
    }

    private func attach(to window: NSWindow) {
        guard window.toolbar == nil else { return }
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

    private func updateFocusedCommandText() {
        guard let tabManager else { return }
        let text: String
        if let selectedId = tabManager.selectedTabId,
           let tab = tabManager.tabs.first(where: { $0.id == selectedId }) {
            let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
            text = title.isEmpty ? "Cmd: —" : "Cmd: \(title)"
        } else {
            text = "Cmd: —"
        }

        for label in commandLabels.values {
            label.stringValue = text
        }
    }

    // MARK: - NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [commandItemIdentifier, .flexibleSpace, updateItemIdentifier]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [commandItemIdentifier, .flexibleSpace, updateItemIdentifier]
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
            updateFocusedCommandText()
            return item
        }

        if itemIdentifier == updateItemIdentifier, let updateViewModel {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let hostingView = NonDraggableHostingView(rootView: UpdatePill(model: updateViewModel))
            let key = ObjectIdentifier(toolbar)
            item.view = hostingView
            updateHostingViews[key] = hostingView

            // Observe state changes to nudge the toolbar into re-laying-out
            // the item when the pill's intrinsic content size changes.
            updateCancellables[key]?.cancel()
            updateCancellables[key] = updateViewModel.$state
                .receive(on: DispatchQueue.main)
                .sink { [weak hostingView] _ in
                    DispatchQueue.main.async { [weak hostingView] in
                        hostingView?.invalidateIntrinsicContentSize()
                    }
                }
            return item
        }

        return nil
    }

}
