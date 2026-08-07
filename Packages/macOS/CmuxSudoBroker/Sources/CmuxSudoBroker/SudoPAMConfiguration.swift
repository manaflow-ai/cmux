public import Foundation

/// Reads the sudo PAM policy used for Touch ID authentication.
public struct SudoPAMConfiguration: Sendable {
    /// The PAM policy file to inspect.
    public let fileURL: URL

    /// Creates a PAM policy reader.
    ///
    /// - Parameter fileURL: The injected policy file, normally /etc/pam.d/sudo_local.
    public init(fileURL: URL = URL(fileURLWithPath: "/etc/pam.d/sudo_local")) {
        self.fileURL = fileURL
    }

    /// Whether the policy file appears to mention pam_tid.so.
    public func touchIDIsEnabled() -> Bool {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return false }
        return Self.containsEnabledEntry(contents)
    }

    /// Parses a PAM policy string for Touch ID support.
    ///
    /// - Parameter contents: The complete PAM policy text.
    /// - Returns: Whether the policy appears to enable pam_tid.so.
    public static func containsEnabledEntry(_ contents: String) -> Bool {
        // Legacy behavior treated any mention as enabled, including comments.
        contents.contains("pam_tid.so")
    }
}
