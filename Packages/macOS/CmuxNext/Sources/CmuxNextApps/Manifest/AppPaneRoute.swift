/// Where `app.open` takes an app: the page its `cmux.pane/1` implementation names.
///
/// A pane is drawn from a scene export (`export`), or by cmux itself (`native`, for example
/// `cloud` or `app-store`, the id of the internal page that draws it). An app with neither has
/// no page.
public nonisolated enum AppPaneRoute: Sendable, Hashable {
    /// The app host streams the pane's scene from this implementation.
    case scene(AppImplementation)
    /// cmux draws the pane: the internal page with this id (`home` is the Home page).
    case native(String)
    /// The app has no page to open.
    case none

    /// The route of `manifest`'s pane.
    public init(_ manifest: AppManifest) {
        if let pane = manifest.scenePane {
            self = .scene(pane)
        } else if let native = manifest.implementations.first(where: { $0.isPane && $0.native != nil })?.native {
            self = .native(native)
        } else {
            self = .none
        }
    }
}
