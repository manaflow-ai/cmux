import AppKit
import CmuxTerminalCore
import GhosttyKit

/// Carries both spellings of the link from the menu item to its action: the
/// raw text for the open coordinator, the resolved URL for the pasteboard.
private final class TerminalLinkMenuPayload: NSObject {
    let rawValue: String
    let url: URL
    let workingDirectory: String?

    init(rawValue: String, url: URL, workingDirectory: String?) {
        self.rawValue = rawValue
        self.url = url
        self.workingDirectory = workingDirectory
    }
}

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
    /// That has a cost worth stating plainly. Ghostty only reports a hovered
    /// link while the link modifier is held, so these items appear on
    /// Cmd-right-click and not on a bare right-click. It is the same gesture
    /// that makes the link clickable in the first place, but it is a gesture,
    /// and a menu that reads the link under the pointer without one needs a
    /// hit-test cmux cannot ask ghostty for yet.
    ///
    /// - Parameters:
    ///   - menu: The context menu being built.
    ///   - pointerLocation: The right-click point in view coordinates, or `nil`
    ///     when the menu was opened from pane chrome outside the terminal
    ///     viewport. `nil` adds nothing: no pointer, no link under it. The
    ///     point itself is not used; ghostty already resolved the link under
    ///     it, and this mirrors ``addRevealInFinderMenuItem(to:surface:pointerLocation:)``.
    func addLinkContextMenuItems(to menu: NSMenu, pointerLocation: NSPoint?) {
        guard pointerLocation != nil, let terminalSurface else { return }

        let workspace = terminalSurface.owningWorkspace()
        let cwd = workspace.flatMap {
            CommandClickFileOpenRouter.resolveWorkingDirectory(
                workspace: $0,
                surfaceId: terminalSurface.id
            )
        }
        // A path printed by a remote shell names a file on that host. Probing
        // it here would either miss or, worse, hit an unrelated local file.
        let fileResolution: TerminalLinkContextMenuPolicy.FileResolution =
            workspace?.canResolveTerminalPathsAgainstLocalFilesystem(surfaceID: terminalSurface.id) == true
            ? .localFilesystem(cwd: cwd)
            : .remoteHost

        let policy = TerminalLinkContextMenuPolicy(
            router: TerminalLinkRouter(hostNormalizer: TerminalBrowserHostNormalizer()),
            embeddedBrowserIsAvailable: BrowserAvailabilitySettings.isEnabled()
        )
        guard let offer = policy.offer(
            forCandidate: terminalSurface.hostedView.linkHoverIndicatorView.url,
            fileResolution: fileResolution
        ) else {
            return
        }

        let payload = TerminalLinkMenuPayload(
            rawValue: offer.rawValue,
            url: offer.url,
            workingDirectory: cwd
        )
        for item in offer.items {
            let menuItem = menu.addItem(
                withTitle: title(for: item),
                action: selector(for: item),
                keyEquivalent: ""
            )
            menuItem.target = self
            menuItem.representedObject = payload
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

    /// Puts the menu item's link on the pasteboard.
    ///
    /// The resolved URL, not the raw text: a user who copies `example.com/docs`
    /// wants something they can paste into an address bar or a message.
    @objc func copyContextMenuLink(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? TerminalLinkMenuPayload else { return }
        // Through the terminal pasteboard service like every other copy in this
        // view, so it serializes with ghostty's own clipboard reads.
        GhosttyApp.terminalPasteboard.writeString(
            payload.url.absoluteString,
            to: GHOSTTY_CLIPBOARD_STANDARD
        )
    }

    private func openContextMenuLink(
        _ sender: NSMenuItem,
        destination: TerminalLinkOpenRequest.Destination
    ) {
        guard let payload = sender.representedObject as? TerminalLinkMenuPayload,
              let terminalSurface else { return }
        // The raw hovered text through the shared coordinator, not the resolved
        // URL and not `NSWorkspace.open`, so the remote-file guard, the
        // cloud-terminal URL rewrite and the embedded browser's own fallbacks
        // all apply here exactly as they do to a click.
        _ = TerminalLinkOpenCoordinator().open(
            TerminalLinkOpenRequest(
                rawValue: payload.rawValue,
                sourceWorkspaceId: tabId,
                sourcePanelId: terminalSurface.id,
                workingDirectory: payload.workingDirectory,
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
