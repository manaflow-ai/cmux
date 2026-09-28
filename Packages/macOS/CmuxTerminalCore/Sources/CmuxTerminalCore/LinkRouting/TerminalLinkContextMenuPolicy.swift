import Foundation

/// Decides what a right-click over a terminal link may offer.
///
/// Cmd-click already opens a link, but it commits the user to one destination:
/// whichever the `openTerminalLinksInCmuxBrowser` setting names. A link is often
/// worth opening the other way round, or worth copying rather than opening at
/// all, and today the only route to either is to select the text by hand. This
/// is the policy behind the context-menu items that close that gap.
///
/// It is separate from ``TerminalLinkRouter`` because the two answer different
/// questions. The router answers "where does this go by default", which is a
/// property of the URL. This answers "what may the user ask for", which also
/// depends on what those requests would mean: offering cmux's browser for a
/// `mailto:` link would be offering something that cannot happen.
///
/// The hardest part is not the schemes, it is that what ghostty highlights is
/// not always a URL. Its default matchers also highlight bare relative paths
/// such as `src/config/url.zig`, and the omnibox resolver will happily turn
/// any scheme-less text holding a dot or a slash into `https://<text>`. Left
/// alone that produces `https://src/config/url.zig`, a host nobody can reach,
/// offered next to a cmd-click that opens the file in the user's editor. Two
/// guards below keep paths out: ``FileResolution`` for the ones that exist on
/// this machine, and the host shape check for the rest.
public struct TerminalLinkContextMenuPolicy: Sendable {
    /// One menu item, in the order it should appear.
    public enum Item: Sendable, Equatable {
        /// Open in cmux's embedded browser, whatever the setting says.
        case openInCmuxBrowser
        /// Hand to the system default browser, whatever the setting says.
        case openInDefaultBrowser
        /// Put the URL on the pasteboard.
        case copyLink
    }

    /// Whether the pane's files are on this machine, and where relative names
    /// are rooted when they are.
    public enum FileResolution: Sendable, Equatable {
        /// Probe relative candidates against `cwd` on the local file system.
        case localFilesystem(cwd: String?)
        /// The pane's files live on another host. Nothing local is probed, so
        /// a path on that host is never mistaken for a file here.
        case remoteHost
    }

    /// What to show, and for which link.
    public struct Offer: Sendable, Equatable {
        /// The text under the pointer, trimmed and otherwise untouched.
        ///
        /// The open items hand this back to the coordinator rather than
        /// ``url``, so opening from the menu resolves through exactly the
        /// steps a click resolves through. A pre-resolved URL would skip them.
        public let rawValue: String
        /// The resolved URL. Shown to nobody; used for the pasteboard.
        public let url: URL
        /// Non-empty, in menu order.
        public let items: [Item]

        public init(rawValue: String, url: URL, items: [Item]) {
            self.rawValue = rawValue
            self.url = url
            self.items = items
        }
    }

    private let router: TerminalLinkRouter
    private let pathResolver: TerminalPathResolver
    private let embeddedBrowserIsAvailable: Bool

    /// Creates a policy.
    ///
    /// - Parameters:
    ///   - router: The same routing decision a click uses.
    ///   - embeddedBrowserIsAvailable: Whether cmux's browser can open
    ///     anything at all. False when the user disabled it or an MDM profile
    ///     did; the item is then dropped rather than shown and quietly
    ///     redirected to the system browser.
    ///   - pathResolver: The file-existence seam, injectable for tests.
    public init(
        router: TerminalLinkRouter,
        embeddedBrowserIsAvailable: Bool = true,
        pathResolver: TerminalPathResolver = TerminalPathResolver()
    ) {
        self.router = router
        self.embeddedBrowserIsAvailable = embeddedBrowserIsAvailable
        self.pathResolver = pathResolver
    }

    /// The items a right-click over `candidate` should add, or `nil` for none.
    ///
    /// - Parameters:
    ///   - candidate: The raw text under the pointer: a hovered link's target,
    ///     which for an OSC 8 hyperlink is not what is displayed.
    ///   - fileResolution: Where, if anywhere, a relative name should be
    ///     looked up.
    public func offer(
        forCandidate candidate: String?,
        fileResolution: FileResolution
    ) -> Offer? {
        guard let candidate else { return nil }
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // A file is not a link, wherever it lives. On this machine that is
        // decidable, so ask the same resolver cmd-click asks.
        if case let .localFilesystem(cwd) = fileResolution,
           pathResolver.resolveOpenURLFileReference(trimmed, cwd: cwd) != nil {
            return nil
        }

        guard let target = router.resolveOpenURLTarget(trimmed) else { return nil }
        let url = target.url

        // Absolute paths and `file://` reach here as file URLs. "Reveal in
        // Finder" and the preferred editor already own those.
        guard !url.isFileURL else { return nil }

        // The other half of the path problem: text with no scheme only became
        // a URL because the omnibox resolver prefixed `https://`. Require what
        // it produced to be shaped like somewhere a browser could go, so
        // `src/config/url.zig` (host `src`) is rejected while `example.com/a`
        // and `localhost:8000` are not. This runs for a remote pane too, where
        // the file check above cannot.
        guard hasPlausibleHost(url, candidate: trimmed) else { return nil }

        switch url.scheme?.lowercased() {
        case "http", "https":
            // cmux's browser is offered where it is both reachable for this
            // URL and switched on. It can still decline the page later (a host
            // whitelist, an external-open pattern) and fall back the way a
            // click does, but those are per-navigation and not knowable here.
            if case .embeddedBrowser = target, embeddedBrowserIsAvailable {
                return Offer(
                    rawValue: trimmed,
                    url: url,
                    items: [.openInCmuxBrowser, .openInDefaultBrowser, .copyLink]
                )
            }
            return Offer(rawValue: trimmed, url: url, items: [.openInDefaultBrowser, .copyLink])
        case .some:
            // `mailto:`, `ssh:` and the rest go to a handler that is not a
            // browser, and naming a browser in the item would be wrong. Copying
            // is the one thing that means what it says for every scheme.
            return Offer(rawValue: trimmed, url: url, items: [.copyLink])
        case nil:
            return nil
        }
    }

    /// Whether a host invented for scheme-less text could name a machine.
    ///
    /// Text that carried its own scheme is trusted as written: the user or the
    /// program that emitted it said what it was.
    private func hasPlausibleHost(_ url: URL, candidate: String) -> Bool {
        guard URL(string: candidate)?.scheme == nil else { return true }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        // A dot covers domains and IPv4, a colon covers IPv6 literals, and
        // `localhost` is the one name with neither that still resolves.
        return host.contains(".") || host.contains(":") || host == "localhost"
    }
}
