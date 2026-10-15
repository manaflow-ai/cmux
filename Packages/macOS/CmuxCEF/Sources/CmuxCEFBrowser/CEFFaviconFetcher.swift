public import CmuxCEF
public import Foundation

/// Downloads a Chromium page's favicon through the page's own request
/// context (the tab's cookies and proxy), so the pane tab shows the site icon
/// as a WebKit tab does (design spec §2: favicon, then spinner, then globe).
///
/// Chromium reports the favicon's URL (`CMUX_SHIM_FAVICON`); the image is
/// fetched with `cmux_shim_download_favicon`, which answers with a
/// `CMUX_SHIM_REPLY` event carrying the HTTP status and a base64 PNG.
/// Only the newest request of a page is kept: a reply for an older favicon
/// URL (the page navigated on) is dropped.
///
/// Reference: cmux Next `CmuxNextBrowser/CEF/CEFRuntime+Favicon.swift`.
@MainActor
public final class CEFFaviconFetcher {
    /// Icon edge in pixels: a 16 pt tab icon on a 2x display, with headroom.
    public static let maxPixels: Int32 = 64
    /// Reply ids of this fetcher, apart from other shim reply users.
    private static var nextReply: Int32 = 0x4641_0000

    private let runtime: CEFRuntime
    private var observer: UUID?
    /// The pending reply id and the page it answers, per browser.
    private var pending: [Int32: (reply: Int32, completion: @MainActor (Data?) -> Void)] = [:]

    public init(runtime: CEFRuntime = .shared) {
        self.runtime = runtime
    }

    deinit {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            if let observer { runtime.removeEventObserver(observer) }
        }
    }

    /// Fetches `url` for `browserID`; `completion` gets PNG data, or nil when
    /// nothing decoded. A newer fetch for the same browser replaces this one.
    public func fetch(_ url: URL, browserID: Int32, completion: @escaping @MainActor (Data?) -> Void) {
        guard let shim = runtime.shim else {
            completion(nil)
            return
        }
        startObserving()
        let reply = Self.nextReply
        Self.nextReply &+= 1
        pending[browserID] = (reply, completion)
        let started = url.absoluteString.withCString { shim.downloadFavicon(browserID, reply, $0, Self.maxPixels) }
        if started == 0 {
            pending[browserID] = nil
            completion(nil)
        }
    }

    /// Drops the pending fetch of `browserID` (the page closed).
    public func cancel(browserID: Int32) {
        pending[browserID] = nil
    }

    private func startObserving() {
        guard observer == nil else { return }
        observer = runtime.addEventObserver { [weak self] event in
            guard case .reply(let browser, let id, _, let base64) = event else { return }
            self?.replyArrived(browser: browser, id: id, base64: base64)
        }
    }

    private func replyArrived(browser: Int32, id: Int32, base64: String) {
        guard let request = pending[browser], request.reply == id else { return }
        pending[browser] = nil
        request.completion(base64.isEmpty ? nil : Data(base64Encoded: base64))
    }
}
