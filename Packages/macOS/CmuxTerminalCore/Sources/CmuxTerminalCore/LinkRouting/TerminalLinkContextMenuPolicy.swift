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

    /// What to show, and for which URL.
    public struct Offer: Sendable, Equatable {
        /// The URL every item in ``items`` acts on.
        public let url: URL
        /// Non-empty, in menu order.
        public let items: [Item]

        public init(url: URL, items: [Item]) {
            self.url = url
            self.items = items
        }
    }

    private let router: TerminalLinkRouter

    public init(router: TerminalLinkRouter) {
        self.router = router
    }

    /// The items a right-click over `candidate` should add, or `nil` for none.
    ///
    /// - Parameter candidate: The raw text under the pointer: a hovered link's
    ///   target, which for an OSC 8 hyperlink is not what is displayed.
    public func offer(forCandidate candidate: String?) -> Offer? {
        guard let candidate, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let target = router.resolveOpenURLTarget(candidate) else { return nil }
        let url = target.url

        // A local file is not a link. "Reveal in Finder" and the preferred
        // editor already own files, and adding "Open in Default Browser" beside
        // them would offer to render someone's source file as a web page.
        guard !url.isFileURL else { return nil }

        switch url.scheme?.lowercased() {
        case "http", "https":
            // The embedded browser is offered only where it can actually load
            // the page. A web URL the router sent to `external` failed host
            // normalization, so cmux's browser has nothing to navigate to.
            if case .embeddedBrowser = target {
                return Offer(url: url, items: [.openInCmuxBrowser, .openInDefaultBrowser, .copyLink])
            }
            return Offer(url: url, items: [.openInDefaultBrowser, .copyLink])
        case .some:
            // `mailto:`, `ssh:` and the rest go to a handler that is not a
            // browser, and naming a browser in the item would be wrong. Copying
            // is the one thing that means what it says for every scheme.
            return Offer(url: url, items: [.copyLink])
        case nil:
            return nil
        }
    }
}
