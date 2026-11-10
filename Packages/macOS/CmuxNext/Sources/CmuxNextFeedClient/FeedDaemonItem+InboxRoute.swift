import Foundation

extension FeedDaemonItem {
    /// The Feed page's Inbox route on this item (`#/inbox?surface=page&item=<id>`, the page's
    /// `routeItem` in model.ts): Needs you's request whose own tab is gone opens the Inbox on it,
    /// and the page selects it in a new Inbox and in one already open. The id is percent-encoded,
    /// so it never adds a route parameter.
    package var inboxRoute: String {
        "#/inbox?surface=page&item=" + (id.addingPercentEncoding(withAllowedCharacters: Self.routeSafe) ?? "")
    }

    private static let routeSafe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~:")
}
