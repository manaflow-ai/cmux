public import Foundation

/// An account as every caller sees it: an opaque per-user `handle`
/// (`acct_…`) and a redacted `display`. The raw email or login it was made
/// from never leaves the code that read it (detection, the CodeRouter
/// client boundary). The handle is stable for one user and one identity,
/// and different on another Mac or user (``AccountLabeler``).
public struct AccountLabel: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
    public let handle: String
    /// A plan or organization name, a user label, a masked key, or a
    /// shortened identity (`s…@e…`). Never matches an email pattern.
    public let display: String

    /// Only ``AccountLabeler`` makes handles. `display` is redacted again
    /// here, so no value of this type can hold an email.
    init(handle: String, display: String) {
        assert(Self.isValidHandle(handle), "not an account handle")
        self.handle = handle
        self.display = EmailRedaction.redactEmails(in: display)
    }

    /// Demo and test data only: the handle is hashed with a fixed, public
    /// key, so it is not per user. Never pass a real identity as `seed`.
    public static func demo(_ seed: String, display: String) -> AccountLabel {
        AccountLabel(handle: AccountLabeler(salt: Data("cmux-demo-account-labels".utf8)).handle(namespace: "demo", identity: seed),
                     display: display)
    }

    /// `acct_` and lowercase base32 characters.
    static func isValidHandle(_ handle: String) -> Bool {
        guard handle.hasPrefix("acct_") else { return false }
        let body = handle.dropFirst(5)
        return !body.isEmpty && body.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("2"..."7").contains($0) }
    }

    private enum CodingKeys: String, CodingKey { case handle = "account", display = "label" }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let handle = try container.decode(String.self, forKey: .handle)
        guard Self.isValidHandle(handle) else {
            throw DecodingError.dataCorruptedError(forKey: .handle, in: container, debugDescription: "not an account handle")
        }
        self.init(handle: handle, display: try container.decode(String.self, forKey: .display))
    }

    public var description: String { "\(handle) (\(display))" }
}
