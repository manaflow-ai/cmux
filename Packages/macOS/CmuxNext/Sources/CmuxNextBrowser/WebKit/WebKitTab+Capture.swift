import WebKit

/// Stop and Block for a WebKit tab's camera and microphone: WebKit ends the capture itself
/// (`setCameraCaptureState(.none)`), and reports the change through the KVO in `observeWebView`.
extension WebKitTab: BrowserCaptureControlling {
    public func stopCapture() {
        Task { [weak self] in
            guard let webView = self?.webView else { return }
            await webView.setCameraCaptureState(.none)
            await webView.setMicrophoneCaptureState(.none)
        }
    }

    public func blockCapture() { blockSiteCapture() }

    /// What WebKit says the page captures now.
    var webKitCapture: BrowserCapture {
        BrowserCapture(video: webView.cameraCaptureState != .none, audio: webView.microphoneCaptureState != .none)
    }
}
