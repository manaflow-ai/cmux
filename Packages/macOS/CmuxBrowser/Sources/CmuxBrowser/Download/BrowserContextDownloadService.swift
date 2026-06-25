public import WebKit
public import Foundation
internal import AppKit

/// Orchestrates the browser context-menu "Download Image", "Download Linked
/// File", and "Copy Image" network/save work.
///
/// Lifted byte-faithfully out of the app-target `CmuxWebView`. The view keeps the
/// `@objc` context-menu action methods (which resolve the clicked URL from app-side
/// capture state), then calls this service to perform the actual cookie-aware fetch,
/// `NSSavePanel` save, and `NSPasteboard` copy. Mirrors the injected-closure
/// precedent of ``BrowserDownloadDelegate``: app-localized strings, the WebKit
/// cookie store / user agent / referer, the downloading-state notification, the
/// fallback-to-native-action dispatch, the point-based JavaScript URL lookups, and
/// the debug log sink all ride in through the injected ``BrowserContextDownloadSeam``.
///
/// `@MainActor`: every body originates on the main actor in the legacy view (the
/// `@objc` actions are main-thread AppKit selectors), and the `NSSavePanel` /
/// `NSPasteboard` work is main-thread-only AppKit. The injected `URLSession` and
/// `Data(contentsOf:)` completions re-enter via the legacy `DispatchQueue.main.async`
/// hops, preserved verbatim, so co-locating the state with its main-actor callers
/// turns the former intra-view calls into plain method calls with no new bridges.
@MainActor
public final class BrowserContextDownloadService {
    /// Pure URL classification (scheme / favicon / image / Google-redirect / MIME),
    /// injected so the same instance the view holds is reused.
    private let urlClassifier: BrowserDownloadURLClassifier

    /// Resolves the saved filename and HTTP-status download decision, injected so
    /// the same construction precedent as ``BrowserDownloadDelegate`` is followed.
    private let filenameResolver: BrowserDownloadFilenameResolver

    /// The app-side seam: WebKit/AppKit state providers and callbacks the service
    /// cannot reach from the package, supplied at construction by the owning view.
    private let seam: BrowserContextDownloadSeam

    /// Creates a context-download service with the URL classifier, filename
    /// resolver, and app-side seam. Mirrors ``BrowserDownloadDelegate``'s
    /// injected-collaborator construction.
    public init(
        urlClassifier: BrowserDownloadURLClassifier,
        filenameResolver: BrowserDownloadFilenameResolver,
        seam: BrowserContextDownloadSeam
    ) {
        self.urlClassifier = urlClassifier
        self.filenameResolver = filenameResolver
        self.seam = seam
    }

    private func debug(_ message: @autoclosure () -> String) {
        seam.log?(message())
    }

    // MARK: - Classifier forwarders

    /// Whether the URL uses a scheme cmux can download directly (`http`, `https`,
    /// `file`).
    public func isDownloadableScheme(_ url: URL) -> Bool {
        urlClassifier.isDownloadableScheme(url)
    }

    /// Whether the URL is a `data:` URL.
    public func isDataURLScheme(_ url: URL) -> Bool {
        urlClassifier.isDataURLScheme(url)
    }

    /// Whether the URL is in a scheme cmux supports for download (downloadable or
    /// `data:`).
    public func isDownloadSupportedScheme(_ url: URL) -> Bool {
        urlClassifier.isDownloadSupportedScheme(url)
    }

    /// The Google-redirect-unwrapped URL when applicable, otherwise the URL
    /// unchanged.
    public func normalizedLinkedDownloadURL(_ url: URL) -> URL {
        urlClassifier.normalizedLinkedDownloadURL(url)
    }

    /// Whether the URL is likely a favicon.
    public func isLikelyFaviconURL(_ url: URL) -> Bool {
        urlClassifier.isLikelyFaviconURL(url)
    }

    /// Whether the URL is likely an image.
    public func isLikelyImageURL(_ url: URL) -> Bool {
        urlClassifier.isLikelyImageURL(url)
    }

    /// The preferred image MIME type inferred from the URL's path extension.
    public func inferredImageMIMEType(from url: URL) -> String? {
        urlClassifier.inferredImageMIMEType(from: url)
    }

    // MARK: - Downloading-state notification

    /// Notifies the owner that a context-menu download is or is not in flight,
    /// hopping to the main thread when invoked off it, exactly as the legacy body.
    public func notifyContextMenuDownloadState(_ downloading: Bool) {
        if Thread.isMainThread {
            seam.onDownloadStateChanged?(downloading)
        } else {
            // The service is `@MainActor`, so callers are normally already on main;
            // this off-main branch (preserved from the legacy `DispatchQueue.main.async`)
            // re-enters the main actor for any caller that reaches it off-main.
            Task { @MainActor in
                self.seam.onDownloadStateChanged?(downloading)
            }
        }
    }

    // MARK: - Download (image / linked file)

    /// Starts a context-menu download of `url`, logging the trace then delegating
    /// to ``downloadURLViaSession(_:suggestedFilename:sender:fallbackAction:fallbackTarget:traceID:)``.
    public func startContextMenuDownload(
        _ url: URL,
        sender: Any?,
        fallbackAction: Selector?,
        fallbackTarget: AnyObject?,
        traceID: String
    ) {
        debug("browser.ctxdl.start trace=\(traceID) url=\(url.absoluteString)")
        downloadURLViaSession(
            url,
            suggestedFilename: nil,
            sender: sender,
            fallbackAction: fallbackAction,
            fallbackTarget: fallbackTarget,
            traceID: traceID
        )
    }

    /// Downloads `url` (cookie-aware for http(s), direct read for `data:`/`file:`),
    /// then presents an `NSSavePanel`. On any rejection or error, runs the native
    /// WebKit fallback action through the seam. Byte-faithful lift of the legacy body.
    public func downloadURLViaSession(
        _ url: URL,
        suggestedFilename: String?,
        sender: Any?,
        fallbackAction: Selector?,
        fallbackTarget: AnyObject?,
        traceID: String
    ) {
        guard isDownloadSupportedScheme(url) else {
            debug(
                "browser.ctxdl.request trace=\(traceID) stage=rejectUnsupportedScheme url=\(url.absoluteString)"
            )
            seam.runFallback?(fallbackAction, fallbackTarget, sender, traceID, "unsupported_scheme")
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        debug(
            "browser.ctxdl.request trace=\(traceID) stage=start scheme=\(scheme) url=\(url.absoluteString)"
        )
        notifyContextMenuDownloadState(true)
        debug("browser.ctxdl.state trace=\(traceID) downloading=1")

        if scheme == "data" {
            // Defer to a later main-actor turn (the legacy `DispatchQueue.main.async`)
            // so the save panel presents after the current event finishes.
            Task { @MainActor in
                guard let parsed = BrowserDataURLPayload(url: url) else {
                    self.notifyContextMenuDownloadState(false)
                    self.debug(
                        "browser.ctxdl.data trace=\(traceID) stage=parseFailure urlLength=\(url.absoluteString.count)"
                    )
                    self.seam.runFallback?(fallbackAction, fallbackTarget, sender, traceID, "data_url_parse_error")
                    return
                }

                let saveName = parsed.suggestedFilename(
                    forSuggestedFilename: suggestedFilename
                )
                self.debug(
                    "browser.ctxdl.data trace=\(traceID) stage=parseSuccess mime=\(parsed.mimeType ?? "nil") bytes=\(parsed.data.count)"
                )

                let savePanel = NSSavePanel()
                savePanel.nameFieldStringValue = saveName
                savePanel.canCreateDirectories = true
                savePanel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                self.notifyContextMenuDownloadState(false)
                self.debug(
                    "browser.ctxdl.data trace=\(traceID) stage=savePrompt shown=1 defaultName=\(saveName)"
                )
                savePanel.begin { result in
                    guard result == .OK, let destURL = savePanel.url else {
                        self.debug(
                            "browser.ctxdl.data trace=\(traceID) stage=savePrompt result=cancel"
                        )
                        return
                    }
                    do {
                        try parsed.data.write(to: destURL, options: .atomic)
                        self.debug(
                            "browser.ctxdl.data trace=\(traceID) stage=saveSuccess path=\(destURL.path)"
                        )
                    } catch {
                        self.debug(
                            "browser.ctxdl.data trace=\(traceID) stage=saveFailure error=\(error.localizedDescription)"
                        )
                        self.seam.runFallback?(fallbackAction, fallbackTarget, sender, traceID, "data_save_write_error")
                    }
                }
            }
            return
        }

        if scheme == "file" {
            // Defer to a later main-actor turn (the legacy `DispatchQueue.main.async`).
            // The synchronous read stays on main exactly as before.
            Task { @MainActor in
                do {
                    let data = try Data(contentsOf: url)
                    self.debug(
                        "browser.ctxdl.file trace=\(traceID) stage=readSuccess bytes=\(data.count) path=\(url.path)"
                    )
                    let filename = suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let saveName = (filename?.isEmpty == false ? filename! : url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent)
                    let savePanel = NSSavePanel()
                    savePanel.nameFieldStringValue = saveName
                    savePanel.canCreateDirectories = true
                    savePanel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                    // Download is already complete; we're now waiting for user save choice.
                    self.notifyContextMenuDownloadState(false)
                    self.debug(
                        "browser.ctxdl.file trace=\(traceID) stage=savePrompt shown=1 defaultName=\(saveName)"
                    )
                    savePanel.begin { result in
                        guard result == .OK, let destURL = savePanel.url else {
                            self.debug(
                                "browser.ctxdl.file trace=\(traceID) stage=savePrompt result=cancel"
                            )
                            return
                        }
                        do {
                            try data.write(to: destURL, options: .atomic)
                            self.debug(
                                "browser.ctxdl.file trace=\(traceID) stage=saveSuccess path=\(destURL.path)"
                            )
                        } catch {
                            self.debug(
                                "browser.ctxdl.file trace=\(traceID) stage=saveFailure error=\(error.localizedDescription)"
                            )
                        }
                    }
                } catch {
                    self.notifyContextMenuDownloadState(false)
                    self.debug(
                        "browser.ctxdl.file trace=\(traceID) stage=readFailure error=\(error.localizedDescription)"
                    )
                    self.seam.runFallback?(fallbackAction, fallbackTarget, sender, traceID, "file_read_error")
                }
            }
            return
        }

        // Run the whole cookie-fetch / network / save flow on the main actor. The
        // cookie read is bridged to `async` via `allCookies(in:)` so the legacy
        // callback's non-`Sendable` captures (fallback target/sender) stay inside
        // this main-isolated scope, and the fetch uses `await data(for:)`,
        // preserving the legacy `URLSession.dataTask` + `DispatchQueue.main.async`
        // shape (request dispatched, completion delivered on main).
        let referer = seam.referer()
        let userAgent = seam.userAgent()
        let cookieStore = seam.cookieStore()
        Task { @MainActor in
            let cookies = await self.allCookies(in: cookieStore)
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            let cookieHeaders = HTTPCookie.requestHeaderFields(with: BrowserDownloadCookieFilter().filter(cookies, url: url))
            for (key, value) in cookieHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }
            if let referer, !referer.isEmpty {
                request.setValue(referer, forHTTPHeaderField: "Referer")
            }
            if let userAgent, !userAgent.isEmpty {
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            }
            self.debug(
                "browser.ctxdl.request trace=\(traceID) stage=dispatch method=\(request.httpMethod ?? "GET") cookies=\(cookies.count) referer=\(request.value(forHTTPHeaderField: "Referer") ?? "nil") uaSet=\(request.value(forHTTPHeaderField: "User-Agent") == nil ? 0 : 1)"
            )
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                self.debug(
                    "browser.ctxdl.response trace=\(traceID) stage=failure hasResponse=0 status=-1 mime=nil error=\(error.localizedDescription)"
                )
                self.notifyContextMenuDownloadState(false)
                self.seam.runFallback?(fallbackAction, fallbackTarget, sender, traceID, "network_error")
                return
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let mime = response.mimeType ?? "nil"
            let expectedLength = response.expectedContentLength
            self.debug("browser.ctxdl.response trace=\(traceID) stage=success hasResponse=1 status=\(statusCode) mime=\(mime) bytes=\(data.count) expected=\(expectedLength)")
            if case .reject = self.filenameResolver.httpStatusDecision(for: response) {
                self.notifyContextMenuDownloadState(false)
                self.seam.runFallback?(fallbackAction, fallbackTarget, sender, traceID, "http_status")
                return
            }
            let saveName = self.filenameResolver.suggestedFilename(suggestedFilename: suggestedFilename, response: response, sourceURL: url, imageData: data)

            let savePanel = NSSavePanel()
            savePanel.nameFieldStringValue = saveName
            savePanel.canCreateDirectories = true
            savePanel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            self.notifyContextMenuDownloadState(false)
            self.debug(
                "browser.ctxdl.response trace=\(traceID) stage=savePrompt shown=1 defaultName=\(saveName)"
            )
            savePanel.begin { result in
                guard result == .OK, let destURL = savePanel.url else {
                    self.debug(
                        "browser.ctxdl.response trace=\(traceID) stage=savePrompt result=cancel"
                    )
                    return
                }
                do {
                    try data.write(to: destURL, options: .atomic)
                    self.debug(
                        "browser.ctxdl.response trace=\(traceID) stage=saveSuccess path=\(destURL.path)"
                    )
                } catch {
                    self.debug(
                        "browser.ctxdl.response trace=\(traceID) stage=saveFailure error=\(error.localizedDescription)"
                    )
                    self.seam.runFallback?(fallbackAction, fallbackTarget, sender, traceID, "save_write_error")
                }
            }
        }
    }

    // MARK: - Copy image

    /// Resolves the source URL for a context-menu "Copy Image": the image under the
    /// cursor when downloadable, else the nearby link when it is itself a likely
    /// image. Uses the seam's point-based JavaScript lookups. Byte-faithful lift.
    public func resolveContextMenuCopyImageSourceURL(
        at point: NSPoint,
        completion: @escaping (URL?) -> Void
    ) {
        seam.findImageURLAtPoint(point) { [weak self] imageURL in
            guard let self else { return completion(nil) }

            if let imageURL {
                let normalized = self.normalizedLinkedDownloadURL(imageURL)
                if self.isDownloadSupportedScheme(normalized) {
                    completion(normalized)
                    return
                }
            }

            self.seam.findLinkURLAtPoint(point) { fallbackLinkURL in
                guard let fallbackLinkURL else {
                    completion(nil)
                    return
                }

                let normalized = self.normalizedLinkedDownloadURL(fallbackLinkURL)
                guard self.isDownloadSupportedScheme(normalized),
                      self.isLikelyImageURL(normalized) else {
                    completion(nil)
                    return
                }

                completion(normalized)
            }
        }
    }

    /// Fetches the image bytes for a "Copy Image" from a `data:`, `file:`, or
    /// http(s) source (cookie-aware for http(s)), then hands back a
    /// ``BrowserImageCopyPasteboardPayload`` or `nil`. Byte-faithful lift.
    public func fetchContextMenuImageCopyPayload(
        from sourceURL: URL,
        traceID: String,
        completion: @escaping (BrowserImageCopyPasteboardPayload?) -> Void
    ) {
        let scheme = sourceURL.scheme?.lowercased() ?? ""
        debug(
            "browser.ctxcopy.fetch trace=\(traceID) stage=start scheme=\(scheme) url=\(sourceURL.absoluteString)"
        )

        if scheme == "data" {
            guard let parsed = BrowserDataURLPayload(url: sourceURL), !parsed.data.isEmpty else {
                debug(
                    "browser.ctxcopy.fetch trace=\(traceID) stage=dataParseFailure"
                )
                completion(nil)
                return
            }
            debug(
                "browser.ctxcopy.fetch trace=\(traceID) stage=dataParseSuccess mime=\(parsed.mimeType ?? "nil") bytes=\(parsed.data.count)"
            )
            completion(
                BrowserImageCopyPasteboardPayload(
                    imageData: parsed.data,
                    mimeType: parsed.mimeType,
                    sourceURL: nil
                )
            )
            return
        }

        if scheme == "file" {
            // Read the file off the main thread, then resume on the main actor to
            // build the payload and call back. Faithful to the legacy
            // `DispatchQueue.global` read + `DispatchQueue.main.async` completion,
            // expressed as a detached read (captures only the Sendable `sourceURL`,
            // returns Sendable `Data?`) so no non-Sendable state crosses the hop.
            Task { @MainActor in
                let data = await Task.detached(priority: .userInitiated) {
                    try? Data(contentsOf: sourceURL)
                }.value
                guard let data, !data.isEmpty else {
                    self.debug(
                        "browser.ctxcopy.fetch trace=\(traceID) stage=fileReadFailure path=\(sourceURL.path)"
                    )
                    completion(nil)
                    return
                }

                self.debug(
                    "browser.ctxcopy.fetch trace=\(traceID) stage=fileReadSuccess bytes=\(data.count) path=\(sourceURL.path)"
                )
                completion(
                    BrowserImageCopyPasteboardPayload(
                        imageData: data,
                        mimeType: self.inferredImageMIMEType(from: sourceURL),
                        sourceURL: nil
                    )
                )
            }
            return
        }

        guard scheme == "http" || scheme == "https" else {
            debug(
                "browser.ctxcopy.fetch trace=\(traceID) stage=unsupportedScheme url=\(sourceURL.absoluteString)"
            )
            completion(nil)
            return
        }

        // See `downloadURLViaSession`: run the cookie read + fetch on the main actor
        // (cookie read bridged via `allCookies(in:)`), so the legacy callback's
        // non-`Sendable` `completion` capture stays in this main-isolated scope.
        let referer = seam.referer()
        let userAgent = seam.userAgent()
        let cookieStore = seam.cookieStore()
        Task { @MainActor in
            let cookies = await self.allCookies(in: cookieStore)
            var request = URLRequest(url: sourceURL)
            request.httpMethod = "GET"
            let cookieHeaders = HTTPCookie.requestHeaderFields(with: cookies)
            for (key, value) in cookieHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }
            if let referer, !referer.isEmpty {
                request.setValue(referer, forHTTPHeaderField: "Referer")
            }
            if let userAgent, !userAgent.isEmpty {
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            }
            self.debug(
                "browser.ctxcopy.fetch trace=\(traceID) stage=dispatch cookies=\(cookies.count) referer=\(request.value(forHTTPHeaderField: "Referer") ?? "nil") uaSet=\(request.value(forHTTPHeaderField: "User-Agent") == nil ? 0 : 1)"
            )
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                self.debug(
                    "browser.ctxcopy.fetch trace=\(traceID) stage=networkFailure status=-1 mime=nil error=\(error.localizedDescription)"
                )
                completion(nil)
                return
            }
            guard !data.isEmpty else {
                self.debug(
                    "browser.ctxcopy.fetch trace=\(traceID) stage=networkFailure status=\((response as? HTTPURLResponse)?.statusCode ?? -1) mime=\(response.mimeType ?? "nil") error=unknown"
                )
                completion(nil)
                return
            }

            let resolvedURL = response.url.flatMap {
                let scheme = $0.scheme?.lowercased() ?? ""
                return (scheme == "http" || scheme == "https") ? $0 : nil
            } ?? sourceURL
            let mimeType = response.mimeType ?? self.inferredImageMIMEType(from: resolvedURL)
            self.debug(
                "browser.ctxcopy.fetch trace=\(traceID) stage=networkSuccess status=\((response as? HTTPURLResponse)?.statusCode ?? -1) mime=\(mimeType ?? "nil") bytes=\(data.count)"
            )
            completion(
                BrowserImageCopyPasteboardPayload(
                    imageData: data,
                    mimeType: mimeType,
                    sourceURL: resolvedURL
                )
            )
        }
    }

    /// Reads all cookies from the store, bridging the callback-based WebKit API to
    /// `async`. The WebKit cookie callback hops to the main actor at runtime; the
    /// `@MainActor` continuation resume keeps the result delivery main-isolated.
    private func allCookies(in store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    /// Writes the copy payload onto `NSPasteboard.general`, guarding against a
    /// pasteboard race. Returns whether it wrote and whether the caller should run
    /// the native fallback. Byte-faithful lift.
    public func writeContextMenuImageCopyPayload(
        _ payload: BrowserImageCopyPasteboardPayload,
        expectedPasteboardChangeCount: Int,
        traceID: String
    ) -> (wrote: Bool, shouldFallback: Bool) {
        let pasteboard = NSPasteboard.general
        if pasteboard.changeCount != expectedPasteboardChangeCount {
            debug(
                "browser.ctxcopy.write trace=\(traceID) stage=skipPasteboardRace expected=\(expectedPasteboardChangeCount) actual=\(pasteboard.changeCount)"
            )
            return (false, false)
        }

        let items = payload.pasteboardItems
        guard !items.isEmpty else {
            debug(
                "browser.ctxcopy.write trace=\(traceID) stage=buildFailure mime=\(payload.mimeType ?? "nil") url=\(payload.sourceURL?.absoluteString ?? "nil") bytes=\(payload.imageData.count)"
            )
            return (false, true)
        }

        _ = pasteboard.clearContents()
        let wrote = pasteboard.writeObjects(items)
        debug(
            "browser.ctxcopy.write trace=\(traceID) stage=finish wrote=\(wrote ? 1 : 0) itemCount=\(items.count) types=\(items.map { $0.types.map(\.rawValue).joined(separator: ",") }.joined(separator: "|"))"
        )
        return (wrote, !wrote)
    }
}
