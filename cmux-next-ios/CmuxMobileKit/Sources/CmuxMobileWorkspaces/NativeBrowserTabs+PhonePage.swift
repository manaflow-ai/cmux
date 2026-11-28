#if os(iOS)
import Foundation
import UIKit
import WebKit

/// An agent on the Mac drives a tab this iPhone shows in its own web view
/// (RFD 0089, `cmux browser tab_…@phone <verb>`). The Mac's link host owns the
/// routing, the verb list and the refusals (`cmux_phone_page`); this answers one
/// verb on the tab's WKWebView with the same result shape the Mac's tab gives.
public extension NativeBrowserTabs {
    /// A refusal the Mac passes on to the agent as `{code, message}`.
    struct PageRefusal: Error, Equatable, Sendable {
        public var code: String
        public var message: String
        public init(_ code: String, _ message: String) {
            self.code = code
            self.message = message
        }
    }

    /// Answers `method` (`browser.page.*`) on `tab` of `macID`: the verb's result
    /// as a JSON object, or a refusal. A tab the phone mirrors from the Mac (not
    /// shown here) is refused `tab_not_on_phone`.
    func answerPageVerb(method: String, params: [String: Any], macID: String?) async -> Result<[String: Any], PageRefusal> {
        guard let tab = params["tab"] as? String,
              let model = model(tab: tab, macID: macID) else {
            return .failure(PageRefusal("tab_not_on_phone", "the iPhone mirrors this tab from the Mac; open it on the iPhone first"))
        }
        let webView = model.webView
        switch method {
        case "browser.page.navigate":
            guard let text = params["url"] as? String, BrowserTabModel.url(for: text) != nil else {
                return .failure(PageRefusal("bad_request", "navigate needs a url"))
            }
            model.navigate(to: text)
            return .success([:])
        case "browser.page.back":
            model.goBack()
            return .success([:])
        case "browser.page.forward":
            model.goForward()
            return .success([:])
        case "browser.page.reload":
            if !model.isLoading { model.reloadOrStop() }
            return .success([:])
        case "browser.page.state":
            return .success([
                "url": (webView.url ?? model.url)?.absoluteString ?? "",
                "title": webView.title ?? model.title,
                "loading": model.isLoading,
            ])
        case "browser.page.eval":
            guard let script = params["script"] as? String else {
                return .failure(PageRefusal("bad_request", "eval needs a script"))
            }
            return await Self.evaluate(script, in: webView).map { ["value": $0] }
        case "browser.page.text":
            let selector = params["selector"] as? String ?? "body"
            guard let quoted = Self.jsonLiteral(selector) else {
                return .failure(PageRefusal("bad_request", "text needs a selector"))
            }
            let script = "(() => { const e = document.querySelector(\(quoted)); return e ? e.innerText : null; })()"
            switch await Self.evaluate(script, in: webView) {
            case .success(let text as String): return .success(["text": text])
            case .success: return .failure(PageRefusal("element_not_found", "no element matches \(selector)"))
            case .failure(let refusal): return .failure(refusal)
            }
        case "browser.page.screenshot":
            return await Self.screenshot(webView)
        default:
            return .failure(PageRefusal("unsupported_verb", "the iPhone's tab does not answer \(method)"))
        }
    }

    /// `text` as a JavaScript string literal.
    private static func jsonLiteral(_ text: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let array = String(data: data, encoding: .utf8) else { return nil }
        return String(array.dropFirst().dropLast())
    }

    /// The script's completion value, as JSON (`NSNull` for undefined or a
    /// value JSON cannot hold). The value crosses as JSON bytes.
    private static func evaluate(_ script: String, in webView: WKWebView) async -> Result<Any, PageRefusal> {
        let json: Result<Data, PageRefusal> = await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(returning: .failure(PageRefusal("js_error", error.localizedDescription)))
                    return
                }
                let wrapped: [Any] = [value.flatMap { JSONSerialization.isValidJSONObject([$0]) ? $0 : nil } ?? NSNull()]
                continuation.resume(returning: .success((try? JSONSerialization.data(withJSONObject: wrapped)) ?? Data("[null]".utf8)))
            }
        }
        return json.map { data in
            ((try? JSONSerialization.jsonObject(with: data)) as? [Any])?.first ?? NSNull()
        }
    }

    /// The visible viewport as a PNG (crosses as bytes and pixel sizes).
    private static func screenshot(_ webView: WKWebView) async -> Result<[String: Any], PageRefusal> {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        let shot: (Data, Int, Int)? = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, _ in
                guard let image, let png = image.pngData() else { return continuation.resume(returning: nil) }
                continuation.resume(returning: (png, Int(image.size.width * image.scale), Int(image.size.height * image.scale)))
            }
        }
        guard let (png, width, height) = shot else {
            return .failure(PageRefusal("screenshot_failed", "the iPhone could not take the tab's picture (is it on screen?)"))
        }
        return .success(["png_base64": png.base64EncodedString(), "width": width, "height": height])
    }
}
#endif
