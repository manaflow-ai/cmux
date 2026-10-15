public import Foundation

/// The "extension added" notice that follows a successful install (prompt id 0).
///
/// cmux shows it on the tab that installed the extension.
public struct BrowserExtensionInstalledNotice: Equatable, Sendable {
    /// The installed extension id.
    public var extensionID: String
    /// The installed extension name.
    public var name: String

    /// Decodes the fork's JSON.
    ///
    /// - Parameter json: The fork's JSON text.
    /// - Returns: nil unless it is an "installed" notice with an id.
    public init?(json: String) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "installed",
              let id = object["extension_id"] as? String, !id.isEmpty else { return nil }
        extensionID = id
        name = object["name"] as? String ?? ""
    }
}
