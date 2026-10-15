public import Foundation

/// A Chromium extension prompt that cmux answers (fork API 12).
///
/// Covers the Web Store's "Add to Chrome", `chrome.permissions.request`
/// (optional permissions), re-enabling after new permissions, and the other
/// Chromium `ExtensionInstallPrompt` types. Chromium waits until cmux replies
/// exactly once; cmux shows its own sheet on the asking tab instead of
/// Chromium's Views dialog.
public struct BrowserExtensionInstallPrompt: Equatable, Sendable, Identifiable {
    /// What Chromium is asking.
    public enum Kind: String, Sendable, Equatable {
        /// Install a new extension (Web Store "Add to Chrome").
        case install
        /// Re-enable an extension that asked for new permissions.
        case reEnable = "re_enable"
        /// Grant optional permissions at runtime (`chrome.permissions.request`).
        case permissions
        /// An extension another program placed on disk.
        case externalInstall = "external_install"
        /// An install that arrived from another device.
        case remoteInstall = "remote_install"
        /// Repair a corrupted extension.
        case repair
        /// Any type this cmux does not know.
        case other
    }

    /// One permission line of the prompt.
    public struct Permission: Equatable, Sendable {
        /// Chromium's localized permission message.
        public var message: String
        /// Extra lines Chromium shows under the message (host lists), or "".
        public var details: String

        /// Creates a permission line.
        public init(message: String, details: String = "") {
            self.message = message
            self.details = details
        }
    }

    /// The person's answer; raw values are the fork's `cmux_install_prompt_result_t`.
    public enum Answer: Int32, Sendable {
        /// The prompt could not be shown (no window): Chromium aborts.
        case abort = 0
        /// The person accepted.
        case accept = 1
        /// The person declined.
        case cancel = 2
    }

    /// Chromium's prompt id; 0 never reaches a prompt (it is the installed notice).
    public var id: Int32
    /// What Chromium is asking.
    public var kind: Kind
    /// The extension id.
    public var extensionID: String
    /// The extension name.
    public var name: String
    /// PNG data of the extension icon, when Chromium had one.
    public var icon: Data?
    /// The permissions the extension asks for.
    public var permissions: [Permission]
    /// Accepting may withhold host permissions (the person grants sites later).
    public var withholdsOnAccept: Bool
    /// The tab the prompt belongs to (0 when Chromium named none).
    public var browser: Int32

    /// Decodes the fork's JSON (`cmux_install_prompt_handler_t`).
    ///
    /// - Parameters:
    ///   - id: Chromium's prompt id.
    ///   - browser: The asking Chromium browser id.
    ///   - json: The fork's JSON text.
    /// - Returns: nil for malformed input or the "installed" notice.
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

    /// Creates a prompt directly (cmux-originated confirmations, tests).
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
}
