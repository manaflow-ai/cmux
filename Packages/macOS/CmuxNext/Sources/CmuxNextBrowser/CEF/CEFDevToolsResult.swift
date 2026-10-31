import CoreGraphics
import Foundation
import ImageIO

/// Parsing of in-process DevTools method results.
nonisolated enum CEFDevToolsResult {
    /// `Runtime.evaluate` with `returnByValue: true`.
    static func evaluation(_ json: String) throws(BrowserTabError) -> BrowserJSValue {
        guard let object = parse(json) else { throw .javaScript("invalid DevTools result") }
        if let details = object["exceptionDetails"] as? [String: Any] {
            let exception = details["exception"] as? [String: Any]
            let message = exception?["description"] as? String ?? details["text"] as? String ?? "exception"
            throw .javaScript(message)
        }
        guard let result = object["result"] as? [String: Any] else { return .null }
        if (result["type"] as? String) == "undefined" { return .null }
        return BrowserJSValue(foundation: result["value"])
    }

    /// `Page.captureScreenshot` (base64 PNG in `data`).
    static func screenshot(_ json: String) throws(BrowserTabError) -> CGImage {
        guard let object = parse(json), let base64 = object["data"] as? String,
              let data = Data(base64Encoded: base64),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw .snapshotUnavailable
        }
        return image
    }

    /// ``evaluation(_:)`` off the caller's actor: a script's value (an agent's DOM snapshot, page
    /// text) is megabytes of JSON, and the caller is the main actor (CEF's UI thread).
    @concurrent
    static func parsedEvaluation(_ json: String) async throws(BrowserTabError) -> BrowserJSValue {
        try evaluation(json)
    }

    /// ``screenshot(_:)`` off the caller's actor: base64 and PNG decoding of a whole page.
    @concurrent
    static func decodedScreenshot(_ json: String) async throws(BrowserTabError) -> CGImage {
        try screenshot(json)
    }

    /// `Page.getFrameTree` main frame id.
    static func mainFrameID(_ json: String) -> String? {
        let tree = parse(json)?["frameTree"] as? [String: Any]
        return (tree?["frame"] as? [String: Any])?["id"] as? String
    }

    /// `Page.createIsolatedWorld` execution context id.
    static func executionContextID(_ json: String) -> Int? {
        (parse(json)?["executionContextId"] as? NSNumber)?.intValue
    }

    /// JSON text for a parameters object, on the caller's actor: only for parameters ``isLarge(_:)`` refuses.
    static func params(_ object: [String: Any]) -> String {
        // `JSONSerialization` raises an Objective-C exception (it does not throw) for a value that is not JSON.
        guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        // A native string: the shim call reads it in place (an `NSString`-backed one is transcoded at the call).
        return String(decoding: data, as: UTF8.self)
    }

    /// ``params(_:)`` off the caller's actor: an app page's script batch or an agent's script is megabytes of
    /// text, and the caller is the main actor (CEF's UI thread).
    @concurrent
    static func encodedParams(_ object: [String: any Sendable]) async -> String {
        params(object)
    }

    /// Text in parameters above which they are encoded off the main actor (``CEFDevToolsCallOrder``). Encoding
    /// 64 KiB takes well under a millisecond; the scripts that stalled the main thread were megabytes.
    static let largeParamsBytes = 64 << 10

    /// Whether `object` holds more than `limit` bytes of strings (keys and values, at any depth). The count
    /// stops at `limit`, and a native string knows its UTF-8 length, so this costs about one step per value.
    static func isLarge(_ object: [String: any Sendable], limit: Int = largeParamsBytes) -> Bool {
        var budget = limit
        return exceeds(object, &budget)
    }

    private static func exceeds(_ value: Any, _ budget: inout Int) -> Bool {
        switch value {
        case let text as String:
            budget -= text.utf8.count
        case let object as [String: Any]:
            for (key, member) in object {
                budget -= key.utf8.count
                if budget < 0 || exceeds(member, &budget) { return true }
            }
        case let items as [Any]:
            for item in items {
                if exceeds(item, &budget) { return true }
            }
        default:
            budget -= 8
        }
        return budget < 0
    }

    private static func parse(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
