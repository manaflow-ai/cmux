import AppKit
import Bonsplit
import ObjectiveC
import UniformTypeIdentifiers
import WebKit


// MARK: - Context menu downloads (image and linked file)
extension CmuxWebView {
    /// Finds the nearest anchor element at a given view-local point.
    /// Used as a context-menu download fallback.
    private func findLinkAtPoint(_ point: NSPoint, completion: @escaping (URL?) -> Void) {
        let flippedY = bounds.height - point.y
        let js = """
        (() => {
            let el = document.elementFromPoint(\(point.x), \(flippedY));
            while (el) {
                if (el.tagName === 'A' && el.href) return el.href;
                el = el.parentElement;
            }
            return '';
        })();
        """
        evaluateJavaScript(js) { result, _ in
            guard let href = result as? String, !href.isEmpty,
                  let url = URL(string: href) else {
                completion(nil)
                return
            }
            completion(url)
        }
    }

    // MARK: - Context menu download support

    struct ParsedDataURL {
        let data: Data
        let mimeType: String?
    }

    static func parseDataURL(_ url: URL) -> ParsedDataURL? {
        let absolute = url.absoluteString
        guard absolute.hasPrefix("data:"),
              let commaIndex = absolute.firstIndex(of: ",") else {
            return nil
        }

        let headerStart = absolute.index(absolute.startIndex, offsetBy: 5)
        let header = String(absolute[headerStart..<commaIndex])
        let payloadStart = absolute.index(after: commaIndex)
        let payload = String(absolute[payloadStart...])

        let segments = header.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        let mimeType = segments.first.flatMap { $0.isEmpty ? nil : $0 }
        let isBase64 = segments.dropFirst().contains { $0.caseInsensitiveCompare("base64") == .orderedSame }

        if isBase64 {
            guard let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]) else {
                return nil
            }
            return ParsedDataURL(data: data, mimeType: mimeType)
        }

        guard let decoded = payload.removingPercentEncoding else { return nil }
        return ParsedDataURL(data: Data(decoded.utf8), mimeType: mimeType)
    }

    private static func filenameExtension(forMIMEType mimeType: String?) -> String? {
        guard let mimeType, !mimeType.isEmpty else { return nil }
        if #available(macOS 11.0, *) {
            if let preferred = UTType(mimeType: mimeType)?.preferredFilenameExtension, !preferred.isEmpty {
                return preferred
            }
        }
        switch mimeType.lowercased() {
        case "image/jpeg":
            return "jpg"
        case "image/png":
            return "png"
        case "image/webp":
            return "webp"
        case "image/gif":
            return "gif"
        case "text/html":
            return "html"
        case "text/plain":
            return "txt"
        default:
            return nil
        }
    }

    private static func suggestedFilenameForDataURL(
        mimeType: String?,
        suggestedFilename: String?
    ) -> String {
        if let suggested = suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines),
           !suggested.isEmpty {
            return suggested
        }
        let ext = filenameExtension(forMIMEType: mimeType) ?? "bin"
        let base = (mimeType?.lowercased().hasPrefix("image/") ?? false) ? "image" : "download"
        return "\(base).\(ext)"
    }

    private func isLikelyFaviconURL(_ url: URL) -> Bool {
        let lower = url.absoluteString.lowercased()
        if lower.contains("favicon") { return true }
        let name = url.lastPathComponent.lowercased()
        return name.hasPrefix("favicon")
    }

    private func notifyContextMenuDownloadState(_ downloading: Bool) {
        if Thread.isMainThread {
            onContextMenuDownloadStateChanged?(downloading)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onContextMenuDownloadStateChanged?(downloading)
            }
        }
    }

    private func downloadURLViaSession(
        _ url: URL,
        suggestedFilename: String?,
        sender: Any?,
        fallbackAction: Selector?,
        fallbackTarget: AnyObject?,
        traceID: String
    ) {
        guard isDownloadSupportedScheme(url) else {
            debugContextDownload(
                "browser.ctxdl.request trace=\(traceID) stage=rejectUnsupportedScheme url=\(url.absoluteString)"
            )
            runContextMenuFallback(
                action: fallbackAction,
                target: fallbackTarget,
                sender: sender,
                traceID: traceID,
                reason: "unsupported_scheme"
            )
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        debugContextDownload(
            "browser.ctxdl.request trace=\(traceID) stage=start scheme=\(scheme) url=\(url.absoluteString)"
        )
        notifyContextMenuDownloadState(true)
        debugContextDownload("browser.ctxdl.state trace=\(traceID) downloading=1")

        if scheme == "data" {
            DispatchQueue.main.async {
                guard let parsed = Self.parseDataURL(url) else {
                    self.notifyContextMenuDownloadState(false)
                    self.debugContextDownload(
                        "browser.ctxdl.data trace=\(traceID) stage=parseFailure urlLength=\(url.absoluteString.count)"
                    )
                    self.runContextMenuFallback(
                        action: fallbackAction,
                        target: fallbackTarget,
                        sender: sender,
                        traceID: traceID,
                        reason: "data_url_parse_error"
                    )
                    return
                }

                let saveName = Self.suggestedFilenameForDataURL(
                    mimeType: parsed.mimeType,
                    suggestedFilename: suggestedFilename
                )
                self.debugContextDownload(
                    "browser.ctxdl.data trace=\(traceID) stage=parseSuccess mime=\(parsed.mimeType ?? "nil") bytes=\(parsed.data.count)"
                )

                let savePanel = NSSavePanel()
                savePanel.nameFieldStringValue = saveName
                savePanel.canCreateDirectories = true
                savePanel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                self.notifyContextMenuDownloadState(false)
                self.debugContextDownload(
                    "browser.ctxdl.data trace=\(traceID) stage=savePrompt shown=1 defaultName=\(saveName)"
                )
                savePanel.begin { result in
                    guard result == .OK, let destURL = savePanel.url else {
                        self.debugContextDownload(
                            "browser.ctxdl.data trace=\(traceID) stage=savePrompt result=cancel"
                        )
                        return
                    }
                    do {
                        try parsed.data.write(to: destURL, options: .atomic)
                        self.debugContextDownload(
                            "browser.ctxdl.data trace=\(traceID) stage=saveSuccess path=\(destURL.path)"
                        )
                    } catch {
                        self.debugContextDownload(
                            "browser.ctxdl.data trace=\(traceID) stage=saveFailure error=\(error.localizedDescription)"
                        )
                        self.runContextMenuFallback(
                            action: fallbackAction,
                            target: fallbackTarget,
                            sender: sender,
                            traceID: traceID,
                            reason: "data_save_write_error"
                        )
                    }
                }
            }
            return
        }

        if scheme == "file" {
            DispatchQueue.main.async {
                do {
                    let data = try Data(contentsOf: url)
                    self.debugContextDownload(
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
                    self.debugContextDownload(
                        "browser.ctxdl.file trace=\(traceID) stage=savePrompt shown=1 defaultName=\(saveName)"
                    )
                    savePanel.begin { result in
                        guard result == .OK, let destURL = savePanel.url else {
                            self.debugContextDownload(
                                "browser.ctxdl.file trace=\(traceID) stage=savePrompt result=cancel"
                            )
                            return
                        }
                        do {
                            try data.write(to: destURL, options: .atomic)
                            self.debugContextDownload(
                                "browser.ctxdl.file trace=\(traceID) stage=saveSuccess path=\(destURL.path)"
                            )
                        } catch {
                            self.debugContextDownload(
                                "browser.ctxdl.file trace=\(traceID) stage=saveFailure error=\(error.localizedDescription)"
                            )
                        }
                    }
                } catch {
                    self.notifyContextMenuDownloadState(false)
                    self.debugContextDownload(
                        "browser.ctxdl.file trace=\(traceID) stage=readFailure error=\(error.localizedDescription)"
                    )
                    self.runContextMenuFallback(
                        action: fallbackAction,
                        target: fallbackTarget,
                        sender: sender,
                        traceID: traceID,
                        reason: "file_read_error"
                    )
                }
            }
            return
        }

        let cookieStore = configuration.websiteDataStore.httpCookieStore
        cookieStore.getAllCookies { cookies in
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            let cookieHeaders = HTTPCookie.requestHeaderFields(with: cookies)
            for (key, value) in cookieHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }
            if let referer = self.url?.absoluteString, !referer.isEmpty {
                request.setValue(referer, forHTTPHeaderField: "Referer")
            }
            if let ua = self.customUserAgent, !ua.isEmpty {
                request.setValue(ua, forHTTPHeaderField: "User-Agent")
            }
            self.debugContextDownload(
                "browser.ctxdl.request trace=\(traceID) stage=dispatch method=\(request.httpMethod ?? "GET") cookies=\(cookies.count) referer=\(request.value(forHTTPHeaderField: "Referer") ?? "nil") uaSet=\(request.value(forHTTPHeaderField: "User-Agent") == nil ? 0 : 1)"
            )

            URLSession.shared.dataTask(with: request) { data, response, error in
                DispatchQueue.main.async {
                    guard let data, error == nil else {
                        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                        let mime = response?.mimeType ?? "nil"
                        let hasResponse = response == nil ? 0 : 1
                        self.debugContextDownload(
                            "browser.ctxdl.response trace=\(traceID) stage=failure hasResponse=\(hasResponse) status=\(statusCode) mime=\(mime) error=\(error?.localizedDescription ?? "unknown")"
                        )
                        self.notifyContextMenuDownloadState(false)
                        self.runContextMenuFallback(
                            action: fallbackAction,
                            target: fallbackTarget,
                            sender: sender,
                            traceID: traceID,
                            reason: "network_error"
                        )
                        return
                    }
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                    let mime = response?.mimeType ?? "nil"
                    let expectedLength = response?.expectedContentLength ?? -1
                    self.debugContextDownload(
                        "browser.ctxdl.response trace=\(traceID) stage=success hasResponse=1 status=\(statusCode) mime=\(mime) bytes=\(data.count) expected=\(expectedLength)"
                    )
                    let filenameCandidate = suggestedFilename
                        ?? response?.suggestedFilename
                        ?? url.lastPathComponent
                    let saveName = filenameCandidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "download" : filenameCandidate

                    let savePanel = NSSavePanel()
                    savePanel.nameFieldStringValue = saveName
                    savePanel.canCreateDirectories = true
                    savePanel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                    // Download is already complete; we're now waiting for user save choice.
                    self.notifyContextMenuDownloadState(false)
                    self.debugContextDownload(
                        "browser.ctxdl.response trace=\(traceID) stage=savePrompt shown=1 defaultName=\(saveName)"
                    )
                    savePanel.begin { result in
                        guard result == .OK, let destURL = savePanel.url else {
                            self.debugContextDownload(
                                "browser.ctxdl.response trace=\(traceID) stage=savePrompt result=cancel"
                            )
                            return
                        }
                        do {
                            try data.write(to: destURL, options: .atomic)
                            self.debugContextDownload(
                                "browser.ctxdl.response trace=\(traceID) stage=saveSuccess path=\(destURL.path)"
                            )
                        } catch {
                            self.debugContextDownload(
                                "browser.ctxdl.response trace=\(traceID) stage=saveFailure error=\(error.localizedDescription)"
                            )
                            self.runContextMenuFallback(
                                action: fallbackAction,
                                target: fallbackTarget,
                                sender: sender,
                                traceID: traceID,
                                reason: "save_write_error"
                            )
                        }
                    }
                }
            }.resume()
        }
    }

    private func startContextMenuDownload(
        _ url: URL,
        sender: Any?,
        fallbackAction: Selector?,
        fallbackTarget: AnyObject?,
        traceID: String
    ) {
        debugContextDownload("browser.ctxdl.start trace=\(traceID) url=\(url.absoluteString)")
        downloadURLViaSession(
            url,
            suggestedFilename: nil,
            sender: sender,
            fallbackAction: fallbackAction,
            fallbackTarget: fallbackTarget,
            traceID: traceID
        )
    }

    @objc func contextMenuDownloadImage(_ sender: Any?) {
        let traceID = Self.makeContextDownloadTraceID(prefix: "img")
        let point = lastContextMenuPoint
        debugContextDownload(
            "browser.ctxdl.click trace=\(traceID) kind=image point=(\(Int(point.x)),\(Int(point.y)))"
        )
        let fallback = fallbackFromSender(
            sender,
            defaultAction: fallbackDownloadImageAction,
            defaultTarget: fallbackDownloadImageTarget
        )
        debugContextDownload(
            "browser.ctxdl.click trace=\(traceID) fallback action=\(Self.selectorName(fallback.action)) target=\(String(describing: fallback.target))"
        )
        findImageURLAtPoint(point) { [weak self] url in
            guard let self else { return }
            self.debugContextDownload(
                "browser.ctxdl.resolve trace=\(traceID) kind=image imageURL=\(url?.absoluteString ?? "nil")"
            )
            var dataImageURL: URL?
            var weakImageURL: URL?
            if let url {
                let scheme = url.scheme?.lowercased() ?? ""
                if scheme == "data" {
                    dataImageURL = url
                    self.debugContextDownload(
                        "browser.ctxdl.resolve trace=\(traceID) kind=image dataURLDetected length=\(url.absoluteString.count)"
                    )
                } else if scheme == "http" || scheme == "https" || scheme == "file" {
                    let normalized = self.normalizedLinkedDownloadURL(url)
                    self.debugContextDownload(
                        "browser.ctxdl.resolve trace=\(traceID) kind=image normalizedImageURL=\(normalized.absoluteString)"
                    )
                    if self.isLikelyImageURL(normalized) {
                        if !self.isLikelyFaviconURL(normalized) {
                            self.startContextMenuDownload(
                                normalized,
                                sender: sender,
                                fallbackAction: fallback.action,
                                fallbackTarget: fallback.target,
                                traceID: traceID
                            )
                            return
                        }
                        weakImageURL = normalized
                        self.debugContextDownload(
                            "browser.ctxdl.resolve trace=\(traceID) kind=image weakCandidateURL=\(normalized.absoluteString) reason=favicon_or_low_confidence"
                        )
                    } else if self.isDownloadableScheme(normalized), !self.isLikelyFaviconURL(normalized) {
                        // Some image CDNs use extensionless URLs; keep as last-resort candidate.
                        weakImageURL = normalized
                        self.debugContextDownload(
                            "browser.ctxdl.resolve trace=\(traceID) kind=image weakCandidateURL=\(normalized.absoluteString) reason=unclassified_direct_image_src"
                        )
                    }
                    self.debugContextDownload(
                        "browser.ctxdl.resolve trace=\(traceID) kind=image rejectedPrimaryImageURL=\(normalized.absoluteString)"
                    )
                }
            }

            // Google Images and similar sites often expose blob:/data: image URLs.
            // If image URL is not directly downloadable, fall back to the nearby link URL.
            self.findLinkURLAtPoint(point) { linkURL in
                self.debugContextDownload(
                    "browser.ctxdl.resolve trace=\(traceID) kind=image fallbackLinkURL=\(linkURL?.absoluteString ?? "nil")"
                )
                if let linkURL {
                    let normalizedLink = self.normalizedLinkedDownloadURL(linkURL)
                    self.debugContextDownload(
                        "browser.ctxdl.resolve trace=\(traceID) kind=image normalizedFallbackLinkURL=\(normalizedLink.absoluteString)"
                    )
                    if self.isDownloadableScheme(normalizedLink),
                       self.isLikelyImageURL(normalizedLink),
                       !self.isLikelyFaviconURL(normalizedLink) {
                        self.startContextMenuDownload(
                            normalizedLink,
                            sender: sender,
                            fallbackAction: fallback.action,
                            fallbackTarget: fallback.target,
                            traceID: traceID
                        )
                        return
                    }
                }

                if let dataImageURL {
                    self.debugContextDownload(
                        "browser.ctxdl.resolve trace=\(traceID) kind=image fallbackToDataURL=1"
                    )
                    self.startContextMenuDownload(
                        dataImageURL,
                        sender: sender,
                        fallbackAction: fallback.action,
                        fallbackTarget: fallback.target,
                        traceID: traceID
                    )
                    return
                }

                if let weakImageURL {
                    self.debugContextDownload(
                        "browser.ctxdl.resolve trace=\(traceID) kind=image fallbackToWeakCandidate=1"
                    )
                    self.startContextMenuDownload(
                        weakImageURL,
                        sender: sender,
                        fallbackAction: fallback.action,
                        fallbackTarget: fallback.target,
                        traceID: traceID
                    )
                    return
                }

                if linkURL != nil {
                    self.debugInspectElementsAtPoint(point, traceID: traceID, kind: "image")
                    self.runContextMenuFallback(
                        action: fallback.action,
                        target: fallback.target,
                        sender: sender,
                        traceID: traceID,
                        reason: "fallback_link_not_image"
                    )
                    return
                }

                self.debugInspectElementsAtPoint(point, traceID: traceID, kind: "image")
                self.runContextMenuFallback(
                    action: fallback.action,
                    target: fallback.target,
                    sender: sender,
                    traceID: traceID,
                    reason: "no_image_or_link_url"
                )
            }
        }
    }

    @objc func contextMenuDownloadLinkedFile(_ sender: Any?) {
        let traceID = Self.makeContextDownloadTraceID(prefix: "lnk")
        let point = lastContextMenuPoint
        debugContextDownload(
            "browser.ctxdl.click trace=\(traceID) kind=linked point=(\(Int(point.x)),\(Int(point.y)))"
        )
        let fallback = fallbackFromSender(
            sender,
            defaultAction: fallbackDownloadLinkedFileAction,
            defaultTarget: fallbackDownloadLinkedFileTarget
        )
        debugContextDownload(
            "browser.ctxdl.click trace=\(traceID) fallback action=\(Self.selectorName(fallback.action)) target=\(String(describing: fallback.target))"
        )
        findLinkURLAtPoint(point) { [weak self] url in
            guard let self else { return }
            self.debugContextDownload(
                "browser.ctxdl.resolve trace=\(traceID) kind=linked linkURL=\(url?.absoluteString ?? "nil")"
            )
            if let url {
                let normalized = self.normalizedLinkedDownloadURL(url)
                self.debugContextDownload(
                    "browser.ctxdl.resolve trace=\(traceID) kind=linked normalizedLinkURL=\(normalized.absoluteString)"
                )
                if self.isDownloadSupportedScheme(normalized) {
                    self.startContextMenuDownload(
                        normalized,
                        sender: sender,
                        fallbackAction: fallback.action,
                        fallbackTarget: fallback.target,
                        traceID: traceID
                    )
                    return
                }
            }

            // Fallback 1: image URL under cursor (useful on image-heavy result pages).
            self.findImageURLAtPoint(point) { imageURL in
                self.debugContextDownload(
                    "browser.ctxdl.resolve trace=\(traceID) kind=linked fallbackImageURL=\(imageURL?.absoluteString ?? "nil")"
                )
                var dataImageURL: URL?
                if let imageURL, self.isDownloadableScheme(imageURL) {
                    self.startContextMenuDownload(
                        imageURL,
                        sender: sender,
                        fallbackAction: fallback.action,
                        fallbackTarget: fallback.target,
                        traceID: traceID
                    )
                    return
                }
                if let imageURL, self.isDataURLScheme(imageURL) {
                    dataImageURL = imageURL
                    self.debugContextDownload(
                        "browser.ctxdl.resolve trace=\(traceID) kind=linked fallbackDataURLDetected length=\(imageURL.absoluteString.count)"
                    )
                }

                // Fallback 2: simpler nearest-anchor lookup.
                self.findLinkAtPoint(point) { fallbackURL in
                    self.debugContextDownload(
                        "browser.ctxdl.resolve trace=\(traceID) kind=linked nearestAnchorURL=\(fallbackURL?.absoluteString ?? "nil")"
                    )
                    guard let fallbackURL else {
                        if let dataImageURL {
                            self.debugContextDownload(
                                "browser.ctxdl.resolve trace=\(traceID) kind=linked fallbackToDataURL=1"
                            )
                            self.startContextMenuDownload(
                                dataImageURL,
                                sender: sender,
                                fallbackAction: fallback.action,
                                fallbackTarget: fallback.target,
                                traceID: traceID
                            )
                            return
                        }
                        self.debugInspectElementsAtPoint(point, traceID: traceID, kind: "linked")
                        self.runContextMenuFallback(
                            action: fallback.action,
                            target: fallback.target,
                            sender: sender,
                            traceID: traceID,
                            reason: "no_link_or_image_url"
                        )
                        return
                    }
                    let normalized = self.normalizedLinkedDownloadURL(fallbackURL)
                    self.debugContextDownload(
                        "browser.ctxdl.resolve trace=\(traceID) kind=linked normalizedNearestAnchorURL=\(normalized.absoluteString)"
                    )
                    guard self.isDownloadSupportedScheme(normalized) else {
                        if let dataImageURL {
                            self.debugContextDownload(
                                "browser.ctxdl.resolve trace=\(traceID) kind=linked fallbackToDataURL=1"
                            )
                            self.startContextMenuDownload(
                                dataImageURL,
                                sender: sender,
                                fallbackAction: fallback.action,
                                fallbackTarget: fallback.target,
                                traceID: traceID
                            )
                            return
                        }
                        self.debugInspectElementsAtPoint(point, traceID: traceID, kind: "linked")
                        self.runContextMenuFallback(
                            action: fallback.action,
                            target: fallback.target,
                            sender: sender,
                            traceID: traceID,
                            reason: "nearest_anchor_unsupported_scheme"
                        )
                        return
                    }
                    self.startContextMenuDownload(
                        normalized,
                        sender: sender,
                        fallbackAction: fallback.action,
                        fallbackTarget: fallback.target,
                        traceID: traceID
                    )
                }
            }
        }
    }
}
