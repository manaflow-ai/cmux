import Foundation
@preconcurrency import WebKit

/// Engine-neutral download handle. Wraps `WKDownload` today; will wrap
/// Chromium's `DownloadItem` when the Chromium backend lands. The
/// identity model matches WK: one `CmuxDownload` per in-flight download,
/// usable as a dictionary key via `ObjectIdentifier(_:)`.
@MainActor
public final class CmuxDownload {
    /// Process-stable identifier for this download. Survives across
    /// host-side bookkeeping; not a Chromium download GUID.
    public let id: UUID

    /// The HTTP request that initiated the download (the navigation
    /// that triggered it). May be `nil` for engine-initiated downloads
    /// (e.g. context-menu "Save Image As").
    public let originalRequest: URLRequest?

    /// Backend-specific download object. WebKit: `WKDownload`.
    /// Chromium: future `download::DownloadItem` C handle. Backends
    /// inspect this via internal accessors; hosts never touch it.
    let wkDownload: WKDownload?

    init(wkDownload: WKDownload?, originalRequest: URLRequest?) {
        self.id = UUID()
        self.wkDownload = wkDownload
        self.originalRequest = originalRequest
    }

    /// Cancel the download. Engine emits a final
    /// `download(_:didFailWithError:resumeData:)` with a cancellation
    /// error so the host's finalization path runs.
    public func cancel() {
        guard let wkDownload else { return }
        wkDownload.cancel { _ in /* resumeData discarded for now */ }
    }
}

/// Engine-neutral counterpart to `WKDownloadDelegate`. Conforming
/// types receive lifecycle callbacks for any `CmuxDownload` they
/// own. Methods mirror the WK shape with `Cmux*` types.
@MainActor
public protocol CmuxDownloadDelegate: AnyObject {
    /// Pick the on-disk destination for the download. Pass `nil` to
    /// reject. The destination URL's parent directory must exist.
    func cmuxDownload(
        _ download: CmuxDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    )

    /// Download succeeded. The file is now at the destination URL
    /// chosen above.
    func cmuxDownloadDidFinish(_ download: CmuxDownload)

    /// Download failed. `resumeData` may be `nil`; when present it
    /// can be passed to a future resume API.
    func cmuxDownload(
        _ download: CmuxDownload,
        didFailWithError error: Error,
        resumeData: Data?
    )
}

public extension CmuxDownloadDelegate {
    func cmuxDownloadDidFinish(_ download: CmuxDownload) {}
    func cmuxDownload(_ download: CmuxDownload, didFailWithError error: Error, resumeData: Data?) {}
}

// MARK: - Navigation delegate extensions for download-initiation hooks

public extension CmuxNavigationDelegate {
    /// Called after the host returns `.download` for a navigation
    /// action. The delegate must attach a `CmuxDownloadDelegate` to
    /// `download.delegate` (when the package exposes it) or store the
    /// returned `CmuxDownload` somewhere the host's download manager
    /// can drive.
    func browserView(
        _ view: CmuxBrowserView,
        navigationAction: CmuxNavigationAction,
        didBecome download: CmuxDownload
    ) {}

    /// Called after the host returns `.download` for a navigation
    /// response (i.e. mid-flight: server replied with attachment).
    func browserView(
        _ view: CmuxBrowserView,
        navigationResponse: CmuxNavigationResponse,
        didBecome download: CmuxDownload
    ) {}
}
