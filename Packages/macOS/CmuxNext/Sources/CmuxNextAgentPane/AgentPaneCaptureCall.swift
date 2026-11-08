public import Foundation

/// What the composer's capture bar asks native for (plans/cmux-next/capture-bar-DESIGN.md,
/// "Contract"): a screenshot (`composer.capture`), a recording of the cmux window
/// (`capture.record.start`, `capture.record.stop`), and Copy or Save of what one made
/// (`capture.copy`, `capture.save`). Parsed here; answered by ``AgentPaneCapture/respond(to:in:)``.
public nonisolated enum AgentPaneCaptureCall: Equatable, Sendable {
    /// `composer.capture {mode}`: `screen`, `window`, `app` or `pane`.
    case shot(mode: String?)
    /// `capture.record.start {cursor, clicks}`: whether the pointer and its clicks are drawn.
    case recordStart(cursor: Bool, clicks: Bool)
    /// `capture.record.stop {}`.
    case recordStop
    /// `capture.copy {data, mimeType} | {path}`; nil when the params break the contract.
    case copy(AgentPaneCapturePayload?)
    /// `capture.save {data, mimeType, name} | {path, name}`; nil when the params break the contract.
    case save(AgentPaneCapturePayload?, name: String?)
    /// `capture.done {}`: the page handled the last screenshot another way (it went into the chat):
    /// its Copy and Save are spent.
    case done

    /// The page ops this parses (AgentPageProvider's allow-list takes them all).
    static let methods: Set<String> = ["composer.capture", "capture.record.start", "capture.record.stop", "capture.copy", "capture.save", "capture.done"]

    init?(method: String, params: [String: Any]?) {
        switch method {
        case "composer.capture": self = .shot(mode: params?["mode"] as? String)
        case "capture.record.start":
            self = .recordStart(cursor: params?["cursor"] as? Bool ?? true, clicks: params?["clicks"] as? Bool ?? false)
        case "capture.record.stop": self = .recordStop
        case "capture.copy": self = .copy(AgentPaneCapturePayload(params))
        case "capture.save": self = .save(AgentPaneCapturePayload(params), name: Self.fileName(params?["name"] as? String))
        case "capture.done": self = .done
        default: return nil
        }
    }

    /// A name for the save panel: its last path component, nil for none, a dot name or one with a NUL.
    static func fileName(_ name: String?) -> String? {
        guard let name, !name.utf8.contains(0) else { return nil }
        let last = (name as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !last.isEmpty, !last.hasPrefix("."), last != "/" else { return nil }
        return String(last.prefix(255))
    }
}

/// What Copy or Save takes: an image's bytes from the page, or a file this bridge wrote (a
/// recording), named by its path. A path is only a claim here: ``AgentPaneRecorder/owned(_:)``
/// decides it, so a page can never make native copy or save an arbitrary file.
public nonisolated enum AgentPaneCapturePayload: Equatable, Sendable {
    case bytes(Data, mimeType: String)
    case file(String)

    /// The image types a capture is (``AgentPaneCapture/fit(_:)``).
    static let imageTypes: Set<String> = ["image/png", "image/jpeg"]
    /// Bytes past this are refused before they are decoded. A capture is never refused for its
    /// size (an over-cap one is the PNG as written), so this is a bound, not the capture cap; Copy
    /// and Save still take only the pane's own shot (``AgentPaneRecorder/takeShot(_:for:)``).
    static let maxBytes = 64 * 1024 * 1024

    init?(_ params: [String: Any]?) {
        if let path = params?["path"] as? String {
            guard params?["data"] == nil, path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
            self = .file(path)
            return
        }
        guard let text = params?["data"] as? String, text.utf8.count <= Self.maxBytes / 3 * 4 + 4,
              let mimeType = params?["mimeType"] as? String, Self.imageTypes.contains(mimeType),
              let data = Data(base64Encoded: text), !data.isEmpty else { return nil }
        self = .bytes(data, mimeType: mimeType)
    }
}
