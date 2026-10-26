import AppKit

/// What a page's shows asked for (a route, a folder, a phone), kept under the key of the tab each
/// show opened or selected until that tab's first show makes its view (``InternalPageView/build()``).
/// A tab opened out of sight makes no page and still opens where it was asked to, as Chrome keeps a
/// background tab's pending navigation until the tab is activated
/// (chrome/browser/sessions/tab_loader.cc, `NavigationController::LoadIfNecessary`).
///
/// A provider runs its show through ``open(_:_:)``, reads the request in
/// ``InternalPageProvider/makeView(for:in:)`` with ``take(for:)`` (the tab's own) and ``running``
/// (a view the show makes in the same turn), and forgets a closed tab's request.
@MainActor
final class PageOpenRequests<Value> {
    /// The request of the show running now, for a view it makes in the same turn.
    private(set) var running: Value?
    /// The request of each tab that came back from a show with no view yet, by provider key.
    private var waiting: [String: Value] = [:]

    init() {}

    /// Runs `body` with `request` as ``running``.
    func during<Output>(_ request: Value?, _ body: () -> Output) -> Output {
        let outer = running
        running = request
        defer { running = outer }
        return body()
    }

    /// Runs `show` (a show or an open of the page) for `request`. A view made in it reads `request`
    /// as ``running``; a tab it returns with no view yet keeps `request` for its first show, in place
    /// of an older one. A nil request keeps nothing (the tab shows what it showed).
    func open(_ request: Value?, _ show: () -> InternalPageView?) -> InternalPageView? {
        let view = during(request, show)
        if let request, let view, !view.isBuilt { waiting[view.key] = request }
        return view
    }

    /// The request tab `key` keeps for its first show, once.
    func take(for key: String) -> Value? { waiting.removeValue(forKey: key) }

    /// The request tab `key` keeps, left in place (its route before its first show).
    func kept(for key: String) -> Value? { waiting[key] }

    /// Tab `key` closed: its request goes.
    func forget(_ key: String) { waiting[key] = nil }
}
