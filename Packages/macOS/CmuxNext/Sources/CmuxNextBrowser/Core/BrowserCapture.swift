public import Foundation

/// The devices a page captures right now, as the engine reports them
/// (Chromium's `CefDisplayHandler::OnMediaAccessChange`, WebKit's
/// `cameraCaptureState` and `microphoneCaptureState`): Chrome's red
/// recording indicator on the tab. Empty while the page captures nothing.
public nonisolated struct BrowserCapture: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The page reads the camera.
    public static let camera = BrowserCapture(rawValue: 1)
    /// The page reads the microphone.
    public static let microphone = BrowserCapture(rawValue: 2)

    /// The page captures camera, microphone or both.
    public var isCapturing: Bool { !isEmpty }

    /// The capture a Chromium report names: `video` for the camera, `audio` for the microphone.
    public init(video: Bool, audio: Bool) {
        var capture: BrowserCapture = []
        if video { capture.insert(.camera) }
        if audio { capture.insert(.microphone) }
        self = capture
    }

    /// The Page Info permissions in use (``PageInfoProviding/pageInfoInUse``).
    public var sitePermissionKinds: Set<SitePermissionKind> {
        var kinds: Set<SitePermissionKind> = []
        if contains(.camera) { kinds.insert(.camera) }
        if contains(.microphone) { kinds.insert(.microphone) }
        return kinds
    }
}

/// A page that can end its capture (the tab's Stop and Block entries).
@MainActor
public protocol BrowserCaptureControlling: AnyObject {
    /// Ends the page's camera and microphone capture now. The site keeps its
    /// permission, so the page may ask again (Chrome's Page Info, set back).
    func stopCapture()
    /// Ends the capture and blocks camera and microphone for the page's site
    /// (Page Info's Block), so it cannot capture again until the person allows it.
    func blockCapture()
}
