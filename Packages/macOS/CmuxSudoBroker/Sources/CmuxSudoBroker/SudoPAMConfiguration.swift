public import Foundation

/// Reads the sudo PAM policy used for Touch ID authentication.
public struct SudoPAMConfiguration: Sendable {
    /// The PAM policy files inspected in precedence order.
    public let fileURLs: [URL]

    /// Creates a reader for the standard local and system sudo policies.
    public init() {
        fileURLs = [
            URL(fileURLWithPath: "/etc/pam.d/sudo_local"),
            URL(fileURLWithPath: "/etc/pam.d/sudo"),
        ]
    }

    /// Creates a reader for one injected PAM policy file.
    ///
    /// - Parameter fileURL: The policy file used instead of the standard locations.
    public init(fileURL: URL) {
        fileURLs = [fileURL]
    }

    /// Creates a reader for multiple injected policy files.
    init(fileURLs: [URL]) {
        self.fileURLs = fileURLs
    }

    /// Whether the policy file appears to mention pam_tid.so.
    ///
    /// - Returns: `true` only for an active `auth sufficient pam_tid.so` entry.
    public func touchIDIsEnabled() -> Bool {
        fileURLs.contains { fileURL in
            guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
                return false
            }
            return Self.containsEnabledEntry(contents)
        }
    }

    /// Parses a PAM policy string for Touch ID support.
    ///
    /// - Parameter contents: The complete PAM policy text.
    /// - Returns: Whether the policy appears to enable pam_tid.so.
    public static func containsEnabledEntry(_ contents: String) -> Bool {
        contents.split(whereSeparator: \.isNewline).contains { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return false }
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.count >= 3
                && fields[0] == "auth"
                && fields[1] == "sufficient"
                && fields[2] == "pam_tid.so"
        }
    }
}
