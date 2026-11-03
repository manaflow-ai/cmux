/// One panel (or drawer view) of a page's developer tools.
///
/// Chromium's DevTools frontend names each panel by an id (`network`,
/// `timeline`, `heap-profiler`); `DevToolsAPI.showPanel(id)` selects it.
/// Safari's Web Inspector (`_WKInspector`) can select only a few of its tabs
/// from the host: the rest need a click in its tab bar.
public nonisolated enum WebDevToolsPanel: String, CaseIterable, Hashable, Sendable {
    case elements
    case console
    case sources
    case network
    case performance
    case memory
    case application
    case lighthouse
    case layers
    case rendering
    case sensors
    case security
    case animations

    /// The Chromium DevTools frontend id `DevToolsAPI.showPanel` takes.
    public var chromiumID: String {
        switch self {
        case .performance: "timeline"
        case .memory: "heap-profiler"
        case .application: "resources"
        default: rawValue
        }
    }

    /// The `_WKInspector` selector that shows this panel, or nil when Web
    /// Inspector has no host API for it.
    public var webKitSelector: String? {
        switch self {
        case .elements: "show"
        case .console: "showConsole"
        case .sources: "showResources"
        default: nil
        }
    }
}
