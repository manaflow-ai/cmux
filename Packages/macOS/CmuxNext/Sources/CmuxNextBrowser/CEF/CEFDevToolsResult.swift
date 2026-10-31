import CmuxNextCompat
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
              let image = blockingImageDecode(data) else {
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

    /// JSON text for a parameters object, as a checked CPU call (``cpuIntensiveCall(size:limit:fileID:line:_:)``):
    /// on the main thread, parameters larger than ``BlockingKind/cpuIntensiveJSONBytes`` are a site.
    static func params(_ object: [String: Any], fileID: StaticString = #fileID, line: UInt = #line) -> String {
        cpuIntensiveCall(size: textSize(object), limit: BlockingKind.cpuIntensiveJSONBytes, fileID: fileID, line: line) {
            guard let data = try? JSONSerialization.data(withJSONObject: object),
                  let text = String(data: data, encoding: .utf8) else { return "{}" }
            return text
        }
    }

    /// ``params(_:fileID:line:)`` off the caller's actor: a call's parameters can be megabytes (a page host's
    /// `Runtime.evaluate` script), and the caller is the main actor (CEF's UI thread). ``CEFDevToolsSendOrder`` keeps
    /// the calls in order meanwhile.
    @concurrent
    static func encodedParams(_ object: [String: any Sendable]) async -> String {
        params(object)
    }

    /// About the JSON text size of `value`, for the CPU gate: each string's UTF-8 bytes, 8 for any other scalar.
    static func textSize(_ value: Any) -> Int {
        switch value {
        case let string as String: string.utf8.count + 2
        case let object as [String: Any]: object.reduce(2) { $0 + $1.key.utf8.count + 3 + textSize($1.value) }
        case let array as [Any]: array.reduce(2) { $0 + textSize($1) + 1 }
        default: 8
        }
    }

    private static func parse(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.blockingJSONObject(with: data)) as? [String: Any]
    }
}
