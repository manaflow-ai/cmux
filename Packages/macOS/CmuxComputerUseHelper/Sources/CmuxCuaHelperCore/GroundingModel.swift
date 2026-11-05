// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os

/// Where the grounding fallback asks a vision model for a point
/// (`computerUse.groundingFallback`, off by default). The cmux app sets
/// `CMUX_CUA_GROUNDING_ENDPOINT` at launch only when the person turned the
/// fallback on; the helper never reads it from a request. The endpoint is an
/// OpenAI-compatible chat completions base URL: mlx-vlm on this Mac or vLLM on
/// a GPU host (scripts/measure/grounding-eval/serve-*.sh). A window's
/// screenshot goes there, so only loopback may be plain http; anything else
/// must be https.
public struct GroundingConfig: Sendable, Equatable {
    public static let endpointKey = "CMUX_CUA_GROUNDING_ENDPOINT"
    public static let modelKey = "CMUX_CUA_GROUNDING_MODEL"

    public let endpoint: URL
    /// The served model name; nil asks the server (`GET /models`, the first).
    public let model: String?

    public init?(environment: [String: String]) {
        guard let text = environment[Self.endpointKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: text), Self.isAcceptable(url) else { return nil }
        endpoint = url
        let model = environment[Self.modelKey]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.model = model.isEmpty ? nil : model
    }

    static func isAcceptable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)
    }
}

/// A grounding model's prompt and answer format, from its model card
/// (the same table as scripts/measure/grounding-eval/grounding_eval.py).
enum GroundingFamily: String, Sendable {
    /// Holo2, Holo3.1, Holo4: JSON `{"x","y"}` in thousandths of the image.
    case holo
    /// OpenCUA: `pyautogui.click(x=, y=)` in pixels of the processor-resized image.
    case opencua
    /// GTA1: `(x,y)` in pixels of the processor-resized image.
    case gta1
    /// UI-Venus-Ground: `[x1,y1,x2,y2]` in pixels of the processor-resized image.
    case venus

    init(modelName: String) {
        let name = modelName.lowercased()
        self = name.contains("opencua") ? .opencua : name.contains("gta1") ? .gta1
            : name.contains("venus") ? .venus : .holo
    }

    /// The vision processor's pixel bounds, from each card (Qwen2.5-VL families only;
    /// Holo answers in thousandths, so its resize does not matter).
    var resize: (factor: Int, minPixels: Int, maxPixels: Int)? {
        switch self {
        case .holo: nil
        case .opencua: (28, 3136, 12_845_056)
        case .gta1: (28, 3136, 4096 * 2160)
        case .venus: (28, 2_000_000, 4_800_000)
        }
    }

    func messages(description: String, imageURL: String, width: Int, height: Int) -> [[String: Any]] {
        let image: [String: Any] = ["type": "image_url", "image_url": ["url": imageURL]]
        func user(_ text: String) -> [String: Any] { ["role": "user", "content": [image, ["type": "text", "text": text]]] }
        switch self {
        case .holo:
            return [user("""
                Localize an element on the GUI image according to the provided target and output a click position.
                 * You must output a valid JSON following the format: \(Self.holoSchema)
                 Your target is:
                \(description)
                """)]
        case .opencua:
            return [["role": "system", "content": "You are a GUI agent. You are given a task and a screenshot of the screen. You need to perform a series of pyautogui actions to complete the task."],
                    user(description)]
        case .gta1:
            let size = resized(width: width, height: height)
            return [["role": "system", "content": """
                You are an expert UI element locator. Given a GUI image and a user's element description, provide the coordinates of the specified element as a single (x,y) point. The image resolution is height \(size.height) and width \(size.width). For elements with area, return the center point.

                Output the coordinate pair exactly:
                (x,y)
                """],
                    user(description)]
        case .venus:
            return [user("Outline the position corresponding to the instruction: \(description). The output should be only [x1,y1,x2,y2].")]
        }
    }

    static let holoSchema = "{'properties': {'x': {'description': 'X coordinate as integer in [0, 1000]', 'maximum': 1000, 'minimum': 0, 'title': 'X', 'type': 'integer'}, 'y': {'description': 'Y coordinate as integer in [0, 1000]', 'maximum': 1000, 'minimum': 0, 'title': 'Y', 'type': 'integer'}}, 'required': ['x', 'y'], 'title': 'VisualLocalizerOutput', 'type': 'object'}"

    /// The answer as a point in the sent image's pixels (width x height), or nil.
    func point(in answer: String, width: Int, height: Int) -> (x: Double, y: Double)? {
        let text = Self.withoutThinking(answer)
        switch self {
        case .holo:
            guard let x = Self.number(after: #"["']?x["']?\s*:\s*"#, in: text),
                  let y = Self.number(after: #"["']?y["']?\s*:\s*"#, in: text) else { return nil }
            return (x / 1000 * Double(width), y / 1000 * Double(height))
        case .opencua:
            guard let x = Self.number(after: #"x\s*=\s*"#, in: text), let y = Self.number(after: #"y\s*=\s*"#, in: text) else { return nil }
            return scaled(x, y, width: width, height: height)
        case .gta1:
            let numbers = Self.numbers(in: text)
            guard numbers.count >= 2 else { return nil }
            return scaled(numbers[0], numbers[1], width: width, height: height)
        case .venus:
            let numbers = Self.numbers(in: text)
            if numbers.count >= 4 {
                return scaled((numbers[0] + numbers[2]) / 2, (numbers[1] + numbers[3]) / 2, width: width, height: height)
            }
            return numbers.count == 2 ? scaled(numbers[0], numbers[1], width: width, height: height) : nil
        }
    }

    /// The size the server's processor resizes a width x height image to.
    func resized(width: Int, height: Int) -> (width: Int, height: Int) {
        guard let resize else { return (width, height) }
        let size = Self.smartResize(height: height, width: width, factor: resize.factor,
                                    minPixels: resize.minPixels, maxPixels: resize.maxPixels)
        return (size.width, size.height)
    }

    private func scaled(_ x: Double, _ y: Double, width: Int, height: Int) -> (x: Double, y: Double) {
        let size = resized(width: width, height: height)
        return (x * Double(width) / Double(size.width), y * Double(height) / Double(size.height))
    }

    /// Qwen2-VL's smart_resize: both sides a multiple of `factor`, area within bounds, aspect kept.
    static func smartResize(height: Int, width: Int, factor: Int, minPixels: Int, maxPixels: Int) -> (height: Int, width: Int) {
        let f = Double(factor)
        var h = max(factor, Int((Double(height) / f).rounded(.toNearestOrEven)) * factor)
        var w = max(factor, Int((Double(width) / f).rounded(.toNearestOrEven)) * factor)
        if h * w > maxPixels {
            let beta = (Double(height * width) / Double(maxPixels)).squareRoot()
            h = max(factor, Int((Double(height) / beta / f).rounded(.down)) * factor)
            w = max(factor, Int((Double(width) / beta / f).rounded(.down)) * factor)
        } else if h * w < minPixels {
            let beta = (Double(minPixels) / Double(height * width)).squareRoot()
            h = Int((Double(height) * beta / f).rounded(.up)) * factor
            w = Int((Double(width) * beta / f).rounded(.up)) * factor
        }
        return (h, w)
    }

    static func withoutThinking(_ text: String) -> String {
        var text = text
        while let open = text.range(of: "<think>"), let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        if let close = text.range(of: "</think>") { text.removeSubrange(text.startIndex..<close.upperBound) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let numberPattern = #"-?\d+(?:\.\d+)?"#

    private static func number(after prefix: String, in text: String) -> Double? {
        guard let range = text.range(of: prefix + numberPattern, options: .regularExpression) else { return nil }
        let match = String(text[range])
        guard let value = match.range(of: numberPattern + "$", options: .regularExpression) else { return nil }
        return Double(match[value])
    }

    private static func numbers(in text: String) -> [Double] {
        var values: [Double] = []
        var rest = text[...]
        while let range = rest.range(of: numberPattern, options: .regularExpression) {
            if let value = Double(rest[range]) { values.append(value) }
            rest = rest[range.upperBound...]
        }
        return values
    }
}

/// A model's answer: a point in the screenshot's own pixels.
struct GroundingAnswer: Sendable, Equatable {
    var x: Double
    var y: Double
    var model: String
    var milliseconds: Int
}

/// Asks a grounding model for a point on one screenshot.
protocol GroundingLocating: Sendable {
    func locate(png: Data, width: Int, height: Int, description: String) async throws -> GroundingAnswer
}

/// The HTTP model behind `GroundingConfig`: one chat completion per question,
/// temperature 0, thinking off, batch 1 (as the eval measured it).
final class HTTPGroundingModel: GroundingLocating, @unchecked Sendable {
    private let config: GroundingConfig
    private let session: URLSession
    private let servedName = OSAllocatedUnfairLock<String?>(initialState: nil)

    init(config: GroundingConfig, timeout: TimeInterval = 30) {
        self.config = config
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.connectionProxyDictionary = [:]
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func locate(png: Data, width: Int, height: Int, description: String) async throws -> GroundingAnswer {
        let model = try await name()
        let family = GroundingFamily(modelName: model)
        let body: [String: Any] = [
            "model": model,
            "messages": family.messages(description: description,
                                        imageURL: "data:image/png;base64," + png.base64EncodedString(),
                                        width: width, height: height),
            "temperature": 0,
            "max_tokens": 128,
            // Holo2 reads `thinking`, Holo3.1 and Holo4 `enable_thinking`; templates ignore the other.
            "chat_template_kwargs": ["enable_thinking": false, "thinking": false],
        ]
        var request = URLRequest(url: config.endpoint.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let started = ContinuousClock.now
        let (data, response) = try await session.data(for: request)
        let elapsed = ContinuousClock.now - started
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw ToolError("The grounding model answered HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw ToolError("The grounding model's answer was not a chat completion.")
        }
        guard let point = family.point(in: content, width: width, height: height) else {
            throw ToolError("The grounding model gave no point for that description.")
        }
        let milliseconds = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        return GroundingAnswer(x: point.x, y: point.y, model: model, milliseconds: milliseconds)
    }

    private func name() async throws -> String {
        if let model = config.model { return model }
        if let cached = servedName.withLock({ $0 }) { return cached }
        let (data, _) = try await session.data(from: config.endpoint.appending(path: "models"))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["data"] as? [[String: Any]], let id = models.first?["id"] as? String else {
            throw ToolError("The grounding server lists no model.")
        }
        servedName.withLock { $0 = id }
        return id
    }
}
