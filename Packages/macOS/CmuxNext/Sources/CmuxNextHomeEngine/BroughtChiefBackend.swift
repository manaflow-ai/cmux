package import CmuxNextSettings
import CmuxNextPages
import Foundation

/// A backend the person brings, as the page sends it (`cmux.chief.backend.add`).
package nonisolated struct BroughtChiefBackend: Equatable {
    package enum Kind: Equatable {
        case command(String, args: [String])
        /// `example` is `anthropic-endpoint` or `openai-endpoint`; an empty `apiKey` sends none.
        case endpoint(example: String, baseURL: String, model: String, apiKey: String)
    }

    package var id, name: String
    package var kind: Kind
    package var replace = false
    package var editEndpoint: String?
    package var endpointPreset: String?
    package var servesCloud: Bool?
    package var validateEndpoint: Bool

    package init(_ params: JSONValue) throws {
        let text = { (key: String) in params[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        name = text("name")
        guard !name.isEmpty else { throw PageError.invalidParams("name is required") }
        let explicitID = text("id")
        editEndpoint = params["edit"]?.stringValue
        endpointPreset = params["preset"]?.stringValue
        servesCloud = params["servesCloud"]?.boolValue
        validateEndpoint = params["validateEndpoint"]?.boolValue ?? false
        if params["edit"] != nil {
            let isLetterOrDigit: (UInt8) -> Bool = { (97...122).contains($0) || (48...57).contains($0) }
            guard let editEndpoint, editEndpoint.utf8.count == 64,
                  editEndpoint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  let first = explicitID.utf8.first, isLetterOrDigit(first), explicitID.utf8.count <= 40,
                  explicitID.utf8.allSatisfy({ isLetterOrDigit($0) || $0 == 45 }),
                  params["replace"]?.stringValue == explicitID else {
                throw PageError.invalidParams("edit needs an existing endpoint id")
            }
            id = explicitID
        } else {
            id = Self.id(for: explicitID.isEmpty ? name : explicitID)
        }
        replace = params["replace"]?.stringValue == id
        switch text("kind") {
        case "command":
            guard editEndpoint == nil else { throw PageError.invalidParams("edit needs an endpoint") }
            guard !text("command").isEmpty else { throw PageError.invalidParams("command is required") }
            kind = .command(text("command"), args: params["args"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        case let example where example == "anthropic-endpoint" || example == "openai-endpoint":
            let baseURL = text("baseUrl")
            guard let url = URL(string: baseURL), url.scheme == "https" || url.scheme == "http", url.host != nil else {
                throw PageError.invalidParams("baseUrl must be an http or https URL")
            }
            guard !text("model").isEmpty else { throw PageError.invalidParams("model is required") }
            let apiKey = params["apiKey"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            kind = .endpoint(example: example, baseURL: baseURL, model: text("model"), apiKey: apiKey)
        default:
            throw PageError.invalidParams("kind must be command, anthropic-endpoint or openai-endpoint")
        }
    }

    /// A profile id from the name: lowercase letters, digits and dashes (`My Backend` -> `my-backend`).
    package static func id(for name: String) -> String {
        var id = ""
        for scalar in name.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                id.unicodeScalars.append(scalar)
            } else if !id.isEmpty, !id.hasSuffix("-") {
                id.append("-")
            }
        }
        while id.count > 40 || id.hasSuffix("-") { id.removeLast() }
        return id.isEmpty ? "my-backend" : id
    }
}
