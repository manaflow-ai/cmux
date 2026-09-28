import AppKit
import CmuxTerminalCore
import GhosttyKit

extension GhosttyNSView {
    /// Adds the link items when the pointer is over a link.
    ///
    /// Cmd-click opens a link one way, decided by
    /// `openTerminalLinksInCmuxBrowser`. These items are how the user asks for
    /// the other way without changing the setting, or asks for the URL itself
    /// rather than a page.
    ///
    /// The target comes from the hover indicator, which is the link ghostty
    /// says the pointer is on. For an OSC 8 hyperlink that is the destination
    /// and not the visible text, so what opens is what a click would have
    /// opened. There is no fallback to the word under the pointer: the
    /// right-click press has already replaced the selection with that word, and
    /// offering to open ordinary prose because it happened to contain a dot is
    /// worse than offering nothing.
    ///
    /// - Parameters:
    ///   - menu: The context menu being built.
    ///   - pointerLocation: The right-click point in view coordinates, or `nil`
    ///     when the menu was opened from pane chrome outside the terminal
    ///     viewport. `nil` adds nothing: no pointer, no link under it.
    func addLinkContextMenuItems(to menu: NSMenu, pointerLocation: NSPoint?) {
        guard pointerLocation != nil,
              let terminalSurface,
              let offer = TerminalLinkContextMenuPolicy(
                  router: TerminalLinkRouter(hostNormalizer: TerminalBrowserHostNormalizer())
              ).offer(forCandidate: terminalSurface.hostedView.linkHoverIndicatorView.url) else {
            return
        }

        for item in offer.items {
            let menuItem = menu.addItem(
                withTitle: title(for: item),
                action: selector(for: item),
                keyEquivalent: ""
            )
            menuItem.target = self
            menuItem.representedObject = offer.url
            menuItem.image = NSImage(systemSymbolName: symbolName(for: item), accessibilityDescription: nil)
        }
        menu.addItem(.separator())
    }

    /// Opens the menu item's link in cmux's embedded browser.
    @objc func openContextMenuLinkInCmuxBrowser(_ sender: NSMenuItem) {
        openContextMenuLink(sender, destination: .cmuxBrowser)
    }

    /// Opens the menu item's link in the system default browser.
    @objc func openContextMenuLinkInDefaultBrowser(_ sender: NSMenuItem) {
        openContextMenuLink(sender, destination: .systemBrowser)
    }

    /// Puts the menu item's link on the general pasteboard.
    @objc func copyContextMenuLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    private func openContextMenuLink(
        _ sender: NSMenuItem,
        destination: TerminalLinkOpenRequest.Destination
    ) {
        guard let url = sender.representedObject as? URL,
              let terminalSurface else { return }
        // Through the shared coordinator, not `NSWorkspace.open` directly, so
        // the cloud-terminal URL rewrite and the embedded browser's own
        // fallbacks apply here exactly as they do to a click.
        _ = TerminalLinkOpenCoordinator().open(
            TerminalLinkOpenRequest(
                rawValue: url.absoluteString,
                sourceWorkspaceId: tabId,
                sourcePanelId: terminalSurface.id,
                workingDirectory: nil,
                destination: destination
            )
        )
    }

    private func title(for item: TerminalLinkContextMenuPolicy.Item) -> String {
        switch item {
        case .openInCmuxBrowser:
            return String(
                localized: "terminalContextMenu.openLinkInCmuxBrowser",
                defaultValue: "Open Link in cmux Browser"
            )
        case .openInDefaultBrowser:
            return String(
                localized: "terminalContextMenu.openLinkInDefaultBrowser",
                defaultValue: "Open Link in Default Browser"
            )
        case .copyLink:
            return String(
                localized: "terminalContextMenu.copyLink",
                defaultValue: "Copy Link"
            )
        }
    }

    private func selector(for item: TerminalLinkContextMenuPolicy.Item) -> Selector {
        switch item {
        case .openInCmuxBrowser:
            return #selector(openContextMenuLinkInCmuxBrowser(_:))
        case .openInDefaultBrowser:
            return #selector(openContextMenuLinkInDefaultBrowser(_:))
        case .copyLink:
            return #selector(copyContextMenuLink(_:))
        }
    }

    private func symbolName(for item: TerminalLinkContextMenuPolicy.Item) -> String {
        switch item {
        case .openInCmuxBrowser:
            return "macwindow"
        case .openInDefaultBrowser:
            return "safari"
        case .copyLink:
            return "link"
        }
    }
}
