public import Foundation

/// A Chromium extension prompt that cmux answers (fork API 12): the Web
/// Store's "Add to Chrome", `chrome.permissions.request` (optional
/// permissions), re-enabling after new permissions, and the other
/// `ExtensionInstallPrompt` types. Chromium waits until cmux replies.
public nonisolated struct ExtensionInstallPrompt: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case install
        case reEnable = "re_enable"
        case permissions
        case externalInstall = "external_install"
        case remoteInstall = "remote_install"
        case repair
        case other
    }

    public struct Permission: Equatable, Sendable {
        public var message: String
        /// Extra lines Chromium shows under the message (host lists), or "".
        public var details: String
    }

    /// Chromium's prompt id; 0 never reaches a prompt (it is the notice).
    public var id: Int32
    public var kind: Kind
    public var extensionID: String
    public var name: String
    /// PNG data of the extension icon, when Chromium had one.
    public var icon: Data?
    public var permissions: [Permission]
    /// Accepting may withhold host permissions (the user grants sites later).
    public var withholdsOnAccept: Bool
    /// The tab the prompt belongs to (0 when Chromium named none).
    public var browser: Int32

    /// Decodes the fork's JSON (include/cef_cmux.h,
    /// cmux_install_prompt_handler_t); nil for malformed input.
    public init?(id: Int32, browser: Int32, json: String) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String, type != "installed" else { return nil }
        self.id = id
        self.browser = browser
        kind = Kind(rawValue: type) ?? .other
        extensionID = object["extension_id"] as? String ?? ""
        name = object["name"] as? String ?? ""
        icon = (object["icon_png"] as? String).flatMap { $0.isEmpty ? nil : Data(base64Encoded: $0) }
        permissions = (object["permissions"] as? [[String: Any]] ?? []).compactMap { item in
            guard let message = item["message"] as? String, !message.isEmpty else { return nil }
            return Permission(message: message, details: item["details"] as? String ?? "")
        }
        withholdsOnAccept = object["withhold_on_accept"] as? Bool ?? false
    }

    public init(id: Int32, kind: Kind, extensionID: String, name: String, icon: Data? = nil,
                permissions: [Permission] = [], withholdsOnAccept: Bool = false, browser: Int32 = 0) {
        self.id = id
        self.kind = kind
        self.extensionID = extensionID
        self.name = name
        self.icon = icon
        self.permissions = permissions
        self.withholdsOnAccept = withholdsOnAccept
        self.browser = browser
    }

    /// The user's answer; raw values are the fork's
    /// `cmux_install_prompt_result_t`.
    public enum Answer: Int32, Sendable {
        case abort = 0
        case accept = 1
        case cancel = 2
    }
}

/// The "extension added" notice that follows a successful install
/// (prompt id 0). Chrome shows a bubble at its toolbar; cmux shows a notice.
public nonisolated struct ExtensionInstalledNotice: Equatable, Sendable {
    public var extensionID: String
    public var name: String

    public init?(json: String) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "installed",
              let id = object["extension_id"] as? String, !id.isEmpty else { return nil }
        extensionID = id
        name = object["name"] as? String ?? ""
    }
}
