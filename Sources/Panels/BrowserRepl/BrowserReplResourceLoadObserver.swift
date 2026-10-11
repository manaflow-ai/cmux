import Foundation
import WebKit

/// Reports a tab's network requests to the REPL through WebKit's resource
/// load delegate SPI (`-[WKWebView _setResourceLoadDelegate:]`).
///
/// The delegate methods are matched by selector, so this class needs no
/// private headers. `install` returns `false` when the SPI is missing; the
/// driver then reports no network events rather than injecting page hooks.
@MainActor
final class BrowserReplResourceLoadObserver: NSObject {
    typealias Emit = (_ event: String, _ payload: [String: Any]) -> Void

    private let emit: Emit
    private var requests: [UInt64: [String: Any]] = [:]
    private weak var webView: WKWebView?

    /// Requests started and not yet finished or failed.
    private(set) var inflightCount = 0
    /// Called whenever `inflightCount` changes.
    var onInflightChange: ((Int) -> Void)?

    init(emit: @escaping Emit) {
        self.emit = emit
    }

    private static let setSelector = NSSelectorFromString("_setResourceLoadDelegate:")

    static var isAvailable: Bool {
        WKWebView.instancesRespond(to: setSelector)
    }

    @discardableResult
    func install(on webView: WKWebView) -> Bool {
        guard webView.responds(to: Self.setSelector) else { return false }
        self.webView = webView
        webView.perform(Self.setSelector, with: self)
        return true
    }

    func uninstall() {
        guard let webView, webView.responds(to: Self.setSelector) else { return }
        webView.perform(Self.setSelector, with: nil)
        self.webView = nil
        requests.removeAll()
        inflightCount = 0
    }

    // MARK: - _WKResourceLoadDelegate

    @objc(webView:resourceLoad:didSendRequest:)
    func webView(_ webView: WKWebView, resourceLoad: NSObject, didSendRequest request: URLRequest) {
        let id = Self.loadID(resourceLoad)
        var payload: [String: Any] = [
            "requestId": String(id),
            "url": request.url?.absoluteString ?? "",
            "method": request.httpMethod ?? "GET",
            "resourceType": Self.resourceType(resourceLoad),
        ]
        if let headers = request.allHTTPHeaderFields {
            payload["headers"] = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        }
        requests[id] = payload
        inflightCount += 1
        onInflightChange?(inflightCount)
        emit("request", payload)
    }

    @objc(webView:resourceLoad:didReceiveResponse:)
    func webView(_ webView: WKWebView, resourceLoad: NSObject, didReceiveResponse response: URLResponse) {
        let id = Self.loadID(resourceLoad)
        var payload = requests[id] ?? Self.fallbackPayload(id: id, resourceLoad: resourceLoad)
        if let http = response as? HTTPURLResponse {
            payload["status"] = http.statusCode
            payload["headers"] = http.allHeaderFields.reduce(into: [String: String]()) { result, entry in
                if let key = entry.key as? String { result[key.lowercased()] = "\(entry.value)" }
            }
        }
        requests[id] = payload
        emit("response", payload)
    }

    @objc(webView:resourceLoad:didCompleteWithError:response:)
    func webView(
        _ webView: WKWebView,
        resourceLoad: NSObject,
        didCompleteWithError error: NSError?,
        response: URLResponse?
    ) {
        let id = Self.loadID(resourceLoad)
        var payload = requests.removeValue(forKey: id) ?? Self.fallbackPayload(id: id, resourceLoad: resourceLoad)
        if let http = response as? HTTPURLResponse, payload["status"] == nil {
            payload["status"] = http.statusCode
        }
        inflightCount = max(0, inflightCount - 1)
        onInflightChange?(inflightCount)
        if let error {
            payload["failure"] = error.localizedDescription
            emit("requestfailed", payload)
        } else {
            emit("requestfinished", payload)
        }
    }

    private static func loadID(_ resourceLoad: NSObject) -> UInt64 {
        guard resourceLoad.responds(to: NSSelectorFromString("resourceLoadID")),
              let number = resourceLoad.value(forKey: "resourceLoadID") as? NSNumber else {
            return UInt64(UInt(bitPattern: ObjectIdentifier(resourceLoad).hashValue))
        }
        return number.uint64Value
    }

    private static func fallbackPayload(id: UInt64, resourceLoad: NSObject) -> [String: Any] {
        var url = ""
        var method = "GET"
        if resourceLoad.responds(to: NSSelectorFromString("originalURL")),
           let original = resourceLoad.value(forKey: "originalURL") as? URL {
            url = original.absoluteString
        }
        if resourceLoad.responds(to: NSSelectorFromString("originalHTTPMethod")),
           let originalMethod = resourceLoad.value(forKey: "originalHTTPMethod") as? String {
            method = originalMethod
        }
        return ["requestId": String(id), "url": url, "method": method, "resourceType": resourceType(resourceLoad)]
    }

    /// Maps `_WKResourceLoadInfoResourceType` to Playwright's resource types.
    private static func resourceType(_ resourceLoad: NSObject) -> String {
        guard resourceLoad.responds(to: NSSelectorFromString("resourceType")),
              let raw = resourceLoad.value(forKey: "resourceType") as? NSNumber else {
            return "other"
        }
        switch raw.intValue {
        case 0: return "manifest"
        case 1: return "ping"
        case 2: return "cspreport"
        case 3: return "document"
        case 4: return "image"
        case 5: return "media"
        case 6: return "object"
        case 7: return "ping"
        case 8: return "script"
        case 9: return "stylesheet"
        case 10: return "xhr"
        case 11: return "xslt"
        default: return "other"
        }
    }
}
