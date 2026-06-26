public import Foundation
public import WebKit
import AppKit

extension BrowserImageCopyPasteboardPayload {
    /// Fetches the bytes for a context-menu "Copy Image" action and resolves a
    /// ``BrowserImageCopyPasteboardPayload``, or `nil` when no image could be
    /// retrieved.
    ///
    /// Mirrors the three source schemes the browser supports: a `data:` URL is
    /// decoded inline on the calling actor, a `file:` URL is read off-main and the
    /// result delivered back on main, and `http(s)` is fetched through the shared
    /// `URLSession` carrying the webview's cookies, `Referer`, and `User-Agent`.
    /// All other schemes resolve `nil`.
    ///
    /// ## Isolation
    ///
    /// `@MainActor`: it touches the main-actor `WKHTTPCookieStore` and delivers
    /// `completion`/`log` on main, exactly as the legacy webview method did. The
    /// off-main `file:` read and the background `URLSession` completion hop back to
    /// main with `DispatchQueue.main.async` + `MainActor.assumeIsolated` (we are
    /// provably on main inside the hop), the same bridge `BrowserCookieRepository`
    /// uses for WebKit main-actor callbacks. The `cookieStore`, `referer`, and
    /// `userAgent` providers are closures so the live webview state is read at the
    /// same point the legacy code read it (the cookie store is only touched on the
    /// `http(s)` path).
    ///
    /// - Parameters:
    ///   - sourceURL: The image source URL to fetch.
    ///   - cookieStore: Provides the webview's cookie store, evaluated only on the
    ///     `http(s)` path.
    ///   - referer: Provides the current page URL used as the `Referer` header.
    ///   - userAgent: Provides the webview's custom user agent, if any.
    ///   - traceID: Correlates the debug log lines for this fetch.
    ///   - log: Receives debug trace lines (DEBUG builds only).
    ///   - completion: Delivers the resolved payload, or `nil` on failure.
    @MainActor
    public static func fetchForContextMenuCopy(
        from sourceURL: URL,
        cookieStore: @escaping @MainActor () -> WKHTTPCookieStore,
        referer: @escaping @MainActor () -> String?,
        userAgent: @escaping @MainActor () -> String?,
        traceID: String,
        log: @escaping @MainActor (String) -> Void,
        completion: @escaping @MainActor (BrowserImageCopyPasteboardPayload?) -> Void
    ) {
        let scheme = sourceURL.scheme?.lowercased() ?? ""
        #if DEBUG
        log("browser.ctxcopy.fetch trace=\(traceID) stage=start scheme=\(scheme) url=\(sourceURL.absoluteString)")
        #endif

        if scheme == "data" {
            guard let parsed = ParsedDataURL(dataURL: sourceURL), !parsed.data.isEmpty else {
                #if DEBUG
                log("browser.ctxcopy.fetch trace=\(traceID) stage=dataParseFailure")
                #endif
                completion(nil)
                return
            }
            #if DEBUG
            log("browser.ctxcopy.fetch trace=\(traceID) stage=dataParseSuccess mime=\(parsed.mimeType ?? "nil") bytes=\(parsed.data.count)")
            #endif
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
                // The off-main read hops back to main to match the legacy
                // `DispatchQueue.main.async` delivery; we are provably on main
                // inside the hop, so `assumeIsolated` calls the @MainActor closures.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let data, !data.isEmpty else {
                            #if DEBUG
                            log("browser.ctxcopy.fetch trace=\(traceID) stage=fileReadFailure path=\(sourceURL.path)")
                            #endif
                            completion(nil)
                            return
                        }

                        #if DEBUG
                        log("browser.ctxcopy.fetch trace=\(traceID) stage=fileReadSuccess bytes=\(data.count) path=\(sourceURL.path)")
                        #endif
                        completion(
                            BrowserImageCopyPasteboardPayload(
                                imageData: data,
                                mimeType: BrowserDownloadURLClassifier(url: sourceURL).inferredImageMIMEType,
                                sourceURL: nil
                            )
                        )
                    }
                }
            }
            return
        }

        guard scheme == "http" || scheme == "https" else {
            #if DEBUG
            log("browser.ctxcopy.fetch trace=\(traceID) stage=unsupportedScheme url=\(sourceURL.absoluteString)")
            #endif
            completion(nil)
            return
        }

        // `WKHTTPCookieStore` is `@MainActor`, so its callback is delivered on main;
        // `MainActor.assumeIsolated` lets the callback body call the @MainActor
        // providers/logger regardless of the SDK's closure-isolation annotation,
        // matching the `BrowserCookieRepository` bridge.
        cookieStore().getAllCookies { cookies in
            MainActor.assumeIsolated {
                var request = URLRequest(url: sourceURL)
                request.httpMethod = "GET"
                let cookieHeaders = HTTPCookie.requestHeaderFields(with: cookies)
                for (key, value) in cookieHeaders {
                    request.setValue(value, forHTTPHeaderField: key)
                }
                if let referer = referer(), !referer.isEmpty {
                    request.setValue(referer, forHTTPHeaderField: "Referer")
                }
                if let ua = userAgent(), !ua.isEmpty {
                    request.setValue(ua, forHTTPHeaderField: "User-Agent")
                }

                #if DEBUG
                log("browser.ctxcopy.fetch trace=\(traceID) stage=dispatch cookies=\(cookies.count) referer=\(request.value(forHTTPHeaderField: "Referer") ?? "nil") uaSet=\(request.value(forHTTPHeaderField: "User-Agent") == nil ? 0 : 1)")
                #endif

                URLSession.shared.dataTask(with: request) { data, response, error in
                // Extract the Sendable bits of the non-Sendable `URLResponse`/`Error`
                // on the background completion thread (pure reads, identical values
                // on any thread), then hop to main to match the legacy delivery.
                let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
                let responseMIME = response?.mimeType
                let responseURL = response?.url
                let errorMessage = error?.localizedDescription
                let hadError = error != nil
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let data, !data.isEmpty, !hadError else {
                            #if DEBUG
                            log("browser.ctxcopy.fetch trace=\(traceID) stage=networkFailure status=\(httpStatus) mime=\(responseMIME ?? "nil") error=\(errorMessage ?? "unknown")")
                            #endif
                            completion(nil)
                            return
                        }

                        let resolvedURL = responseURL.flatMap { url -> URL? in
                            let scheme = url.scheme?.lowercased() ?? ""
                            return (scheme == "http" || scheme == "https") ? url : nil
                        } ?? sourceURL
                        let mimeType = responseMIME ?? BrowserDownloadURLClassifier(url: resolvedURL).inferredImageMIMEType
                        #if DEBUG
                        log("browser.ctxcopy.fetch trace=\(traceID) stage=networkSuccess status=\(httpStatus) mime=\(mimeType ?? "nil") bytes=\(data.count)")
                        #endif
                        completion(
                            BrowserImageCopyPasteboardPayload(
                                imageData: data,
                                mimeType: mimeType,
                                sourceURL: resolvedURL
                            )
                        )
                    }
                }
                }.resume()
            }
        }
    }

    /// Writes this payload's image items to the general pasteboard when the
    /// pasteboard has not changed since `expectedPasteboardChangeCount`, returning
    /// whether the write happened and whether the caller should fall back to the
    /// native context-menu action.
    ///
    /// `@MainActor` because it mutates `NSPasteboard.general` and is driven from the
    /// main-actor webview context.
    @MainActor
    public func writeToContextMenuPasteboard(
        expectedPasteboardChangeCount: Int,
        traceID: String,
        log: (String) -> Void
    ) -> (wrote: Bool, shouldFallback: Bool) {
        let pasteboard = NSPasteboard.general
        if pasteboard.changeCount != expectedPasteboardChangeCount {
            #if DEBUG
            log("browser.ctxcopy.write trace=\(traceID) stage=skipPasteboardRace expected=\(expectedPasteboardChangeCount) actual=\(pasteboard.changeCount)")
            #endif
            return (false, false)
        }

        let items = pasteboardItems
        guard !items.isEmpty else {
            #if DEBUG
            log("browser.ctxcopy.write trace=\(traceID) stage=buildFailure mime=\(mimeType ?? "nil") url=\(sourceURL?.absoluteString ?? "nil") bytes=\(imageData.count)")
            #endif
            return (false, true)
        }

        _ = pasteboard.clearContents()
        let wrote = pasteboard.writeObjects(items)
        #if DEBUG
        log("browser.ctxcopy.write trace=\(traceID) stage=finish wrote=\(wrote ? 1 : 0) itemCount=\(items.count) types=\(items.map { $0.types.map(\.rawValue).joined(separator: ",") }.joined(separator: "|"))")
        #endif
        return (wrote, !wrote)
    }
}
