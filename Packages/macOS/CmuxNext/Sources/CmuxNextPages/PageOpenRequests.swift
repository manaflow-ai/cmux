import Foundation

/// A page tab's view as a show returns it: its provider key, and whether its content was made
/// (the tab showed) or waits for its first show.
@MainActor
public protocol PageOpenTarget: AnyObject {
    var key: String { get }
    var isBuilt: Bool { get }
}

/// What a page's shows asked for (a route, a folder, a phone), kept under the key of the tab each
/// show opened or selected until that tab's first show makes its content. A tab opened out of
/// sight makes no page and still opens where it was asked to, as Chrome keeps a background tab's
/// pending navigation until the tab is activated (chrome/browser/sessions/tab_loader.cc,
/// `NavigationController::LoadIfNecessary`).
///
/// A page provider runs its show through ``open(_:_:)``, reads the request where it makes the
/// tab's content with ``take(for:)`` (the tab's own) and ``running`` (content the show makes in
/// the same turn), and forgets a closed tab's request.
@MainActor
public final class PageOpenRequests<Value> {
    /// The request of the show running now, for content it makes in the same turn.
    public private(set) var running: Value?
    /// The request of each tab that came back from a show with no content yet, by provider key.
    private var waiting: [String: Value] = [:]

    public init() {}

    // A generic main-actor class: an isolated deinit crashes the Release optimizer (#23050).
    nonisolated deinit {}

    /// Runs `body` with `request` as ``running``.
    public func during<Output>(_ request: Value?, _ body: () -> Output) -> Output {
        let outer = running
        running = request
        defer { running = outer }
        return body()
    }

    /// Runs `show` (a show or an open of the page) for `request`. Content made in it reads
    /// `request` as ``running``; a tab it returns with no content yet keeps `request` for its first
    /// show, in place of an older one. A nil request keeps nothing (the tab shows what it showed).
    public func open<Shown: PageOpenTarget>(_ request: Value?, _ show: () -> Shown?) -> Shown? {
        let shown = during(request, show)
        if let request, let shown, !shown.isBuilt { waiting[shown.key] = request }
        return shown
    }

    /// The request tab `key` keeps for its first show, once.
    public func take(for key: String) -> Value? { waiting.removeValue(forKey: key) }

    /// The request tab `key` keeps, left in place (its route before its first show).
    public func kept(for key: String) -> Value? { waiting[key] }

    /// Tab `key` closed: its request goes.
    public func forget(_ key: String) { waiting[key] = nil }
}
