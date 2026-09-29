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

    /// `Page.getFrameTree` main frame id.
    static func mainFrameID(_ json: String) -> String? {
        let tree = parse(json)?["frameTree"] as? [String: Any]
        return (tree?["frame"] as? [String: Any])?["id"] as? String
    }

    /// `Page.createIsolatedWorld` execution context id.
    static func executionContextID(_ json: String) -> Int? {
        (parse(json)?["executionContextId"] as? NSNumber)?.intValue
    }

    /// JSON text for a parameters object.
    static func params(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private static func parse(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
