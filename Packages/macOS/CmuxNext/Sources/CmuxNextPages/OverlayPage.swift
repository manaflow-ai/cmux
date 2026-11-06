public import AppKit
public import CmuxNextSettings

public extension PageDescriptor {
    /// The overlay page (webviews/src/pages/overlay): the React drawing of what shows over a window's
    /// content, dialogs (`#/dialog`) and toasts (`#/toasts`). Its native owners stream it state and take
    /// its presses under `cmux.overlay.`; it calls nothing else. A first click in an inactive window
    /// only brings the window forward (no dialog button answers it).
    static let overlay = PageDescriptor(id: "cmux.overlay", resource: "overlay", namespaces: ["cmux.overlay."],
                                        commands: [], acceptsFirstMouse: false)
}

/// Overlay page views of one route, kept warm, so showing an overlay is a state push into a loaded
/// document, never a page load: the card is drawn by the time the overlay host fades it in.
///
/// One spare is loaded ahead (``prewarm()``) and handed out by ``claim()``; a released view becomes the
/// spare again when there is none, else it closes. So the pool holds at most one idle view, whatever
/// the number of windows, plus one per overlay showing now.
@MainActor
public final class OverlayPagePool<Provider: PageProvider> {
    public let route: String
    private let makeProvider: @MainActor () -> Provider
    private var spare: (view: PageWebView, provider: Provider)?
    private var claimed: [ObjectIdentifier: Provider] = [:]

    public init(route: String, makeProvider: @escaping @MainActor () -> Provider) {
        self.route = route
        self.makeProvider = makeProvider
    }

    // A generic main-actor class's isolated deinit crashes the Release optimizer (#23050).
    nonisolated deinit {}

    /// Loads the spare now when there is none.
    public func prewarm() {
        guard spare == nil else { return }
        spare = make()
    }

    /// A loaded (or loading) view and its provider for one overlay; nil when the page is not in the bundle.
    public func claim() -> (view: PageWebView, provider: Provider)? {
        guard let page = spare ?? make() else { return nil }
        spare = nil
        claimed[ObjectIdentifier(page.view)] = page.provider
        page.view.isHidden = false
        return page
    }

    /// The provider of a claimed view.
    public func provider(of view: PageWebView) -> Provider? { claimed[ObjectIdentifier(view)] }

    /// The overlay `view` drew left the screen.
    public func release(_ view: PageWebView) {
        guard let provider = claimed.removeValue(forKey: ObjectIdentifier(view)) else { return }
        if spare == nil, view.loaded {
            spare = (view, provider)
        } else {
            view.close()
        }
    }

    private func make() -> (view: PageWebView, provider: Provider)? {
        let provider = makeProvider()
        guard let view = PageWebView(descriptor: .overlay, routes: [PageRoute(prefix: "cmux.overlay.", provider: provider)],
                                     route: route) else { return nil }
        view.autoresizingMask = []
        return (view, provider)
    }
}
