// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// `point_at_element`: find an element by description, with a grounding model
/// as the fallback for windows whose accessibility tree is thin (canvas apps,
/// games, Electron and Figma-type apps). Only present when the person turned
/// `computerUse.groundingFallback` on (`GroundingConfig`); every other tool
/// passes through unchanged.
///
/// It observes only: one `get_window_state` through `inner`, so the target
/// guard and the machine consent check run exactly as for that call, then
///   1. an element whose label holds every word of the description answers
///      from the tree (`source: "ax"`, no model call);
///   2. a thin tree (fewer than `thinTreeNamedElements` labelled actionable
///      elements, or a degraded walk) asks the model for a point on the
///      screenshot (`source: "grounding"`, window-local screenshot pixels and
///      that screenshot's `capture_id`, which `click` accepts);
///   3. a full tree with no match answers `source: "none"` with the closest
///      labels: the tree is right there, so no screenshot leaves the helper.
public struct GroundingTools: ToolInvoking {
    public static let toolName = "point_at_element"
    /// A window with fewer labelled actionable elements than this is thin.
    static let thinTreeNamedElements = 8

    private let inner: any ToolInvoking
    private let model: any GroundingLocating

    public init(inner: any ToolInvoking, config: GroundingConfig) {
        self.init(inner: inner, model: HTTPGroundingModel(config: config))
    }

    init(inner: any ToolInvoking, model: any GroundingLocating) {
        self.inner = inner
        self.model = model
    }

    public func listTools() async throws -> Data {
        // The driver's inventory is `{"tools": [...]}` or a bare array (acpmux reads both).
        let listed = try JSONSerialization.jsonObject(with: try await inner.listTools())
        func adding(_ tools: [[String: Any]]) -> [[String: Any]] {
            tools.filter { $0["name"] as? String != Self.toolName } + [Self.descriptor]
        }
        if var object = listed as? [String: Any], let tools = object["tools"] as? [[String: Any]] {
            object["tools"] = adding(tools)
            return try JSONSerialization.data(withJSONObject: object)
        }
        guard let tools = listed as? [[String: Any]] else { throw ToolError("The driver's tool list has no tools.") }
        return try JSONSerialization.data(withJSONObject: adding(tools))
    }

    public func invoke(name: String, arguments: Data) async throws -> Data {
        guard name == Self.toolName else { return try await inner.invoke(name: name, arguments: arguments) }
        guard let args = try JSONSerialization.jsonObject(with: arguments) as? [String: Any],
              let description = (args["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !description.isEmpty, let pid = args["pid"], let windowID = args["window_id"] else {
            throw ToolError("point_at_element needs pid, window_id and a non-empty description.")
        }
        var state: [String: Any] = ["pid": pid, "window_id": windowID,
                                    "include_accessibility_tree": true, "include_screenshot": true]
        if let session = args["session"] as? String { state["session"] = session }
        let observed = try await inner.invoke(name: "get_window_state",
                                              arguments: JSONSerialization.data(withJSONObject: state))
        let window = try WindowState(observed)

        if let match = window.bestMatch(for: description), match.coversEveryWord {
            return try Self.result(text: "Found \"\(match.label)\" in the accessibility tree.", fields: [
                "source": "ax", "label": match.label, "element_index": match.element["element_index"] ?? NSNull(),
                "element_token": match.element["element_token"] ?? NSNull(), "frame": match.element["frame"] ?? NSNull(),
                "named_elements": window.namedElements,
            ])
        }
        guard window.isThin(threshold: Self.thinTreeNamedElements) else {
            let closest = window.closest(to: description, limit: 5)
            return try Self.result(text: "No element matches \"\(description)\"; the accessibility tree is full, so read it with get_window_state.", fields: [
                "source": "none", "named_elements": window.namedElements,
                "closest": closest.map { ["label": $0.label, "element_index": $0.element["element_index"] ?? NSNull()] },
            ])
        }
        guard let png = window.screenshot, let width = window.width, let height = window.height else {
            throw ToolError("The window's screenshot is unavailable (\(window.screenshotError ?? "no image")), so the grounding model cannot look.")
        }
        let answer = try await model.locate(png: png, width: width, height: height, description: description)
        let x = min(max(answer.x, 0), Double(width - 1)).rounded()
        let y = min(max(answer.y, 0), Double(height - 1)).rounded()
        var fields: [String: Any] = [
            "source": "grounding", "x": x, "y": y, "screenshot_width": width, "screenshot_height": height,
            "model": answer.model, "model_ms": answer.milliseconds, "named_elements": window.namedElements,
        ]
        if let capture = window.captureID { fields["capture_id"] = capture }
        return try Self.result(
            text: "The grounding model points at (\(Int(x)), \(Int(y))) in the window's screenshot. Pass x, y\(window.captureID == nil ? "" : " and capture_id") to click.",
            fields: fields)
    }

    static var descriptor: [String: Any] { [
        "name": toolName,
        "description": """
            Find an element by a short description (e.g. "the red Export button", "the brush size slider") and \
            return where it is. Answers from the accessibility tree when an element's label matches. When the \
            window's tree is thin (canvas apps, games, Electron and Figma-type apps), a vision model finds it on \
            the window's screenshot and this returns window-local screenshot pixels x, y plus the screenshot's \
            capture_id: pass all three to click. Observes only; never clicks.
            """,
        "inputSchema": [
            "type": "object",
            "required": ["pid", "window_id", "description"],
            "properties": [
                "pid": ["type": "integer", "description": "Target process ID."],
                "window_id": ["type": "integer", "description": "Target window ID from list_windows."],
                "description": ["type": "string", "description": "What the element looks like or says, and where it is."],
                "session": ["type": "string", "description": "The session label used on the other calls, if any."],
            ],
        ],
        "annotations": ["readOnlyHint": true, "title": "Point at element"],
    ] }

    static func result(text: String, fields: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "content": [["type": "text", "text": text]],
            "structuredContent": fields,
            "isError": false,
        ])
    }
}

/// The parts of a `get_window_state` result the fallback reads.
struct WindowState {
    struct Match {
        let element: [String: Any]
        let label: String
        let score: Double
        let coversEveryWord: Bool
    }

    let elements: [[String: Any]]
    let degraded: Bool
    let screenshot: Data?
    let width: Int?
    let height: Int?
    let captureID: String?
    let screenshotError: String?

    init(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolError("get_window_state did not answer with an object.")
        }
        let structured = object["structuredContent"] as? [String: Any] ?? object["structured_content"] as? [String: Any] ?? [:]
        elements = structured["elements"] as? [[String: Any]] ?? []
        degraded = structured["degraded"] as? Bool == true || structured["degraded_reason"] != nil
        width = (structured["screenshot_width"] as? NSNumber)?.intValue
        height = (structured["screenshot_height"] as? NSNumber)?.intValue
        captureID = structured["capture_id"] as? String
        screenshotError = (structured["screenshot_error"] as? [String: Any])?["code"] as? String
        let image = (object["content"] as? [[String: Any]] ?? []).first { $0["type"] as? String == "image" }
        screenshot = (image?["data"] as? String).flatMap { Data(base64Encoded: $0) }
    }

    /// Actionable elements with a label: what an agent can name.
    var named: [(element: [String: Any], label: String)] {
        elements.compactMap { element in
            guard element["element_index"] != nil,
                  let label = (element["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !label.isEmpty else { return nil }
            return (element, label)
        }
    }

    var namedElements: Int { named.count }

    func isThin(threshold: Int) -> Bool { degraded || namedElements < threshold }

    func bestMatch(for description: String) -> Match? { closest(to: description, limit: 1).first }

    /// Labelled elements by the share of the description's words their label holds.
    func closest(to description: String, limit: Int) -> [Match] {
        let wanted = Self.words(description)
        guard !wanted.isEmpty else { return [] }
        return named.compactMap { entry -> Match? in
            let have = Self.words(entry.label)
            let hits = wanted.filter(have.contains).count
            guard hits > 0 else { return nil }
            return Match(element: entry.element, label: entry.label, score: Double(hits) / Double(wanted.count),
                         coversEveryWord: hits == wanted.count)
        }
        .sorted { $0.score != $1.score ? $0.score > $1.score : $0.label.count < $1.label.count }
        .prefix(limit).map { $0 }
    }

    /// Lowercased words of two or more letters, without words that describe
    /// rather than name ("the button", "icon", "top").
    static func words(_ text: String) -> Set<String> {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return Set(words.filter { $0.count > 1 && !filler.contains($0) })
    }

    static let filler: Set<String> = [
        "the", "a", "an", "of", "to", "in", "on", "at", "and", "or", "for", "with", "that", "this",
        "button", "icon", "field", "menu", "item", "link", "tab", "label", "element", "control", "box",
        "top", "bottom", "left", "right", "corner", "side", "panel", "area", "window", "click", "select",
    ]
}
