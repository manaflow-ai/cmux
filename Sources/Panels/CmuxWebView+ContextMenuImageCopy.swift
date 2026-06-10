import AppKit
import Bonsplit
import ObjectiveC
import UniformTypeIdentifiers
import WebKit


// MARK: - Context menu copy image
extension CmuxWebView {
    private func inferredImageMIMEType(from url: URL) -> String? {
        guard !url.pathExtension.isEmpty,
              let type = UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .image) else {
            return nil
        }
        return type.preferredMIMEType
    }

    private func resolveContextMenuCopyImageSourceURL(
        at point: NSPoint,
        completion: @escaping (URL?) -> Void
    ) {
        findImageURLAtPoint(point) { [weak self] imageURL in
            guard let self else { return completion(nil) }

            if let imageURL {
                let normalized = self.normalizedLinkedDownloadURL(imageURL)
                if self.isDownloadSupportedScheme(normalized) {
                    completion(normalized)
                    return
                }
            }

            self.findLinkURLAtPoint(point) { fallbackLinkURL in
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

    private func fetchContextMenuImageCopyPayload(
        from sourceURL: URL,
        traceID: String,
        completion: @escaping (BrowserImageCopyPasteboardPayload?) -> Void
    ) {
        let scheme = sourceURL.scheme?.lowercased() ?? ""
        debugContextDownload(
            "browser.ctxcopy.fetch trace=\(traceID) stage=start scheme=\(scheme) url=\(sourceURL.absoluteString)"
        )

        if scheme == "data" {
            guard let parsed = Self.parseDataURL(sourceURL), !parsed.data.isEmpty else {
                debugContextDownload(
                    "browser.ctxcopy.fetch trace=\(traceID) stage=dataParseFailure"
                )
                completion(nil)
                return
            }
            debugContextDownload(
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
            DispatchQueue.global(qos: .userInitiated).async {
                let data = try? Data(contentsOf: sourceURL)
                DispatchQueue.main.async {
                    guard let data, !data.isEmpty else {
                        self.debugContextDownload(
                            "browser.ctxcopy.fetch trace=\(traceID) stage=fileReadFailure path=\(sourceURL.path)"
                        )
                        completion(nil)
                        return
                    }

                    self.debugContextDownload(
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
            }
            return
        }

        guard scheme == "http" || scheme == "https" else {
            debugContextDownload(
                "browser.ctxcopy.fetch trace=\(traceID) stage=unsupportedScheme url=\(sourceURL.absoluteString)"
            )
            completion(nil)
            return
        }

        let cookieStore = configuration.websiteDataStore.httpCookieStore
        cookieStore.getAllCookies { cookies in
            var request = URLRequest(url: sourceURL)
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
                "browser.ctxcopy.fetch trace=\(traceID) stage=dispatch cookies=\(cookies.count) referer=\(request.value(forHTTPHeaderField: "Referer") ?? "nil") uaSet=\(request.value(forHTTPHeaderField: "User-Agent") == nil ? 0 : 1)"
            )

            URLSession.shared.dataTask(with: request) { data, response, error in
                DispatchQueue.main.async {
                    guard let data, !data.isEmpty, error == nil else {
                        self.debugContextDownload(
                            "browser.ctxcopy.fetch trace=\(traceID) stage=networkFailure status=\((response as? HTTPURLResponse)?.statusCode ?? -1) mime=\(response?.mimeType ?? "nil") error=\(error?.localizedDescription ?? "unknown")"
                        )
                        completion(nil)
                        return
                    }

                    let resolvedURL = response?.url.flatMap {
                        let scheme = $0.scheme?.lowercased() ?? ""
                        return (scheme == "http" || scheme == "https") ? $0 : nil
                    } ?? sourceURL
                    let mimeType = response?.mimeType ?? self.inferredImageMIMEType(from: resolvedURL)
                    self.debugContextDownload(
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
            }.resume()
        }
    }

    private func writeContextMenuImageCopyPayload(
        _ payload: BrowserImageCopyPasteboardPayload,
        expectedPasteboardChangeCount: Int,
        traceID: String
    ) -> (wrote: Bool, shouldFallback: Bool) {
        let pasteboard = NSPasteboard.general
        if pasteboard.changeCount != expectedPasteboardChangeCount {
            debugContextDownload(
                "browser.ctxcopy.write trace=\(traceID) stage=skipPasteboardRace expected=\(expectedPasteboardChangeCount) actual=\(pasteboard.changeCount)"
            )
            return (false, false)
        }

        let items = BrowserImageCopyPasteboardBuilder.makePasteboardItems(from: payload)
        guard !items.isEmpty else {
            debugContextDownload(
                "browser.ctxcopy.write trace=\(traceID) stage=buildFailure mime=\(payload.mimeType ?? "nil") url=\(payload.sourceURL?.absoluteString ?? "nil") bytes=\(payload.imageData.count)"
            )
            return (false, true)
        }

        _ = pasteboard.clearContents()
        let wrote = pasteboard.writeObjects(items)
        debugContextDownload(
            "browser.ctxcopy.write trace=\(traceID) stage=finish wrote=\(wrote ? 1 : 0) itemCount=\(items.count) types=\(items.map { $0.types.map(\.rawValue).joined(separator: ",") }.joined(separator: "|"))"
        )
        return (wrote, !wrote)
    }

    // MARK: - Drag-and-drop passthrough

    @objc func contextMenuCopyImage(_ sender: Any?) {
        let traceID = Self.makeContextDownloadTraceID(prefix: "cpy")
        let point = lastContextMenuPoint
        let pasteboardChangeCount = NSPasteboard.general.changeCount
        debugContextDownload(
            "browser.ctxcopy.click trace=\(traceID) point=(\(Int(point.x)),\(Int(point.y)))"
        )

        let fallback = fallbackFromSender(
            sender,
            defaultAction: fallbackCopyImageAction,
            defaultTarget: fallbackCopyImageTarget
        )
        debugContextDownload(
            "browser.ctxcopy.click trace=\(traceID) fallback action=\(Self.selectorName(fallback.action)) target=\(String(describing: fallback.target))"
        )

        resolveContextMenuCopyImageSourceURL(at: point) { [weak self] sourceURL in
            guard let self else { return }
            guard let sourceURL else {
                self.debugContextDownload(
                    "browser.ctxcopy.resolve trace=\(traceID) stage=noSourceURL"
                )
                self.debugInspectElementsAtPoint(point, traceID: traceID, kind: "copy")
                self.runContextMenuFallback(
                    action: fallback.action,
                    target: fallback.target,
                    sender: sender,
                    traceID: traceID,
                    reason: "no_copy_image_url"
                )
                return
            }

            self.debugContextDownload(
                "browser.ctxcopy.resolve trace=\(traceID) stage=resolved url=\(sourceURL.absoluteString)"
            )
            self.fetchContextMenuImageCopyPayload(from: sourceURL, traceID: traceID) { payload in
                guard let payload else {
                    self.debugContextDownload(
                        "browser.ctxcopy.resolve trace=\(traceID) stage=noPayload"
                    )
                    self.runContextMenuFallback(
                        action: fallback.action,
                        target: fallback.target,
                        sender: sender,
                        traceID: traceID,
                        reason: "copy_image_fetch_failed"
                    )
                    return
                }

                let writeResult = self.writeContextMenuImageCopyPayload(
                    payload,
                    expectedPasteboardChangeCount: pasteboardChangeCount,
                    traceID: traceID
                )
                if writeResult.wrote {
                    return
                }
                if !writeResult.shouldFallback {
                    return
                }

                self.runContextMenuFallback(
                    action: fallback.action,
                    target: fallback.target,
                    sender: sender,
                    traceID: traceID,
                    reason: "copy_image_write_failed"
                )
            }
        }
    }

}
