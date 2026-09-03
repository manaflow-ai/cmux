import Combine
import Foundation

/// Observable mirror of the engine's load state. Today the WebKit
/// backend pushes values from KVO observations on its `WKWebView`;
/// the Chromium backend will push from its navigation delegate. Both
/// hosts subscribe to the same Combine surface.
@MainActor
public final class CmuxBrowserState: ObservableObject {
    @Published public internal(set) var url: URL?
    @Published public internal(set) var title: String?
    @Published public internal(set) var isLoading: Bool = false
    @Published public internal(set) var estimatedProgress: Double = 0
    @Published public internal(set) var canGoBack: Bool = false
    @Published public internal(set) var canGoForward: Bool = false
    /// Page zoom factor, 1.0 = no zoom.
    @Published public internal(set) var pageZoom: CGFloat = 1.0

    public init() {}
}
