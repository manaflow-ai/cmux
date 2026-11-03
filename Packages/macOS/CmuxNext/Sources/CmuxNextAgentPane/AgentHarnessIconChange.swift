public import CmuxNextSettings
import Foundation

/// What Settings' icon chooser asks for one harness (user 12922): a typed value, an image the
/// person chose, or Automatic.
///
/// The page sends `cmux.settings.agents.run {action: "icon", id, ...}`; ``init(_:)`` reads its
/// params and ``params(id:)`` builds the `_acpmux/harness/icon` request
/// (``AcpmuxHarnessMethod/icon``). acpmux checks the value itself and answers why it refuses one.
///
/// ```swift
/// let change = AgentHarnessIconChange(["icon": "🦊"])
/// change?.params(id: "acme") // ["id": "acme", "icon": "🦊"]
/// ```
public nonisolated enum AgentHarnessIconChange: Equatable, Sendable {
    /// One emoji, an SF Symbol name or an agent mark id.
    case value(String)
    /// The base64 bytes of a PNG or SVG (`ext` is `png` or `svg`); acpmux copies it next to the
    /// profile.
    case image(base64: String, ext: String)
    /// Remove the profile's icon line: acpmux picks the icon again.
    case clear

    /// The change the page's params name, or nil when they name none (or an image of another type).
    /// - Parameter params: The page's `cmux.settings.agents.run` params.
    public init?(_ params: JSONValue) {
        if params["clear"]?.boolValue == true {
            self = .clear
        } else if let data = params["data"]?.stringValue, !data.isEmpty {
            let ext = (params["ext"]?.stringValue ?? "png").lowercased()
            guard ext == "png" || ext == "svg" else { return nil }
            self = .image(base64: data, ext: ext)
        } else if let icon = params["icon"]?.stringValue?.trimmingCharacters(in: .whitespaces), !icon.isEmpty {
            self = .value(icon)
        } else {
            return nil
        }
    }

    /// The `_acpmux/harness/icon` params for harness `id`.
    /// - Parameter id: The harness id (a profile in the user's harness folder).
    /// - Returns: `{id, icon}`, `{id, data, ext}` or `{id, clear: true}`.
    public func params(id: String) -> [String: any Sendable] {
        switch self {
        case .value(let icon): ["id": id, "icon": icon]
        case .image(let data, let ext): ["id": id, "data": data, "ext": ext]
        case .clear: ["id": id, "clear": true]
        }
    }
}
