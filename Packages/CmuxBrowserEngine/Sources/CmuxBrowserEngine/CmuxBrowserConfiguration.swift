import Foundation

/// Engine-neutral configuration for a `CmuxBrowserView`.
///
/// Mirrors the subset of `WKWebViewConfiguration` that cmux's BrowserPanel
/// actually consumes today. Add fields here as migration callsites need
/// them, not preemptively.
public final class CmuxBrowserConfiguration: @unchecked Sendable {
    /// Which engine backend the view should use. Defaults to
    /// `CmuxBrowserEngine.defaultKind`.
    public var engineKind: CmuxBrowserEngine.Kind = CmuxBrowserEngine.defaultKind

    /// Optional explicit profile name. Two views with the same profile
    /// name share cookies, local storage, and service workers. `nil`
    /// means the default profile.
    public var profileName: String?

    /// User content controller. Mutating after a view is constructed
    /// has no effect on existing views; pass a configured controller at
    /// construction time.
    public var userContentController: CmuxUserContentController = .init()

    /// Allow JavaScript to open windows without user gesture. Matches
    /// `WKWebView.configuration.preferences.javaScriptCanOpenWindowsAutomatically`.
    public var allowsJavaScriptToOpenWindowsAutomatically: Bool = false

    /// Allow inline media playback (no fullscreen requirement).
    public var allowsInlineMediaPlayback: Bool = true

    /// Require user action to start media playback.
    public var mediaTypesRequiringUserActionForPlayback: MediaPlaybackRequirement = .none

    /// Allow Picture-in-Picture controls in HTMLMediaElement.
    public var allowsPictureInPictureMediaPlayback: Bool = true

    /// Custom User-Agent string. `nil` means use the engine's default UA.
    public var customUserAgent: String?

    /// Custom application name suffix appended to the default User-Agent
    /// (when `customUserAgent` is `nil`).
    public var applicationNameForUserAgent: String?

    /// Process-pool sharing tag. Views with the same tag (and same
    /// profile) share renderer processes when the backend supports it.
    /// `nil` falls back to the engine default.
    public var processPoolTag: String?

    /// Suppresses incremental rendering — frames are only flushed once
    /// the page has finished loading. Almost always `false`.
    public var suppressesIncrementalRendering: Bool = false

    /// Set of URL schemes the host registers custom handlers for, mapped
    /// to the handler instance. Engine-specific scheme handling lives in
    /// the backend.
    public var urlSchemeHandlers: [String: any CmuxURLSchemeHandler] = [:]

    public init() {}

    public enum MediaPlaybackRequirement: Sendable {
        case none
        case audio
        case video
        case all
    }
}

/// Host-side handler for a custom URL scheme. Backends bridge this to
/// `WKURLSchemeHandler` (WebKit) or the Chromium custom scheme API.
public protocol CmuxURLSchemeHandler: AnyObject, Sendable {
    func startURLSchemeTask(_ task: CmuxURLSchemeTask)
    func stopURLSchemeTask(_ task: CmuxURLSchemeTask)
}

/// A single in-flight custom-scheme request. Engine-neutral wrapper
/// around the engine's task object.
public final class CmuxURLSchemeTask: @unchecked Sendable {
    public let request: URLRequest
    private let respondImpl: @Sendable (URLResponse) -> Void
    private let dataImpl: @Sendable (Data) -> Void
    private let finishImpl: @Sendable () -> Void
    private let failImpl: @Sendable (Error) -> Void

    public init(
        request: URLRequest,
        respond: @escaping @Sendable (URLResponse) -> Void,
        data: @escaping @Sendable (Data) -> Void,
        finish: @escaping @Sendable () -> Void,
        fail: @escaping @Sendable (Error) -> Void
    ) {
        self.request = request
        self.respondImpl = respond
        self.dataImpl = data
        self.finishImpl = finish
        self.failImpl = fail
    }

    public func didReceive(_ response: URLResponse) { respondImpl(response) }
    public func didReceive(_ data: Data) { dataImpl(data) }
    public func didFinish() { finishImpl() }
    public func didFailWithError(_ error: Error) { failImpl(error) }
}
