import CryptoKit
public import Foundation

/// Makes ``AccountLabel``s. The handle is `acct_` + base32 (lowercase, no
/// padding) of the first 16 bytes of HMAC-SHA256(per-user salt,
/// "<namespace>:<normalized identity>"), where the namespace is the
/// provider id and the identity is NFC-normalized, trimmed and lowercased. Without the
/// salt a handle cannot be turned back into an email or matched across
/// users. The salt is never printed.
public struct AccountLabeler: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let key: SymmetricKey

    public init(salt: Data) {
        key = SymmetricKey(data: salt)
    }

    public var description: String { "AccountLabeler(<redacted>)" }
    public var debugDescription: String { description }
    /// `dump` and the debugger never show the salt.
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }

    /// The opaque handle of one identity under one provider.
    public func handle(namespace: String, identity: String) -> String {
        let normalized = identity.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mac = HMAC<SHA256>.authenticationCode(for: Data("\(namespace):\(normalized)".utf8), using: key)
        return "acct_" + Self.base32(Array(mac).prefix(16))
    }

    /// A local sign-in: the display is the plan or organization name when
    /// there is one, else the redacted identity (`s…@e…`, `o…`).
    public func local(_ provider: AIProvider, identity: String, plan: String? = nil) -> AccountLabel {
        let display = plan?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? EmailRedaction.redact(identity: identity)
        return AccountLabel(handle: handle(namespace: provider.rawValue, identity: identity), display: display)
    }

    /// A local Codex (ChatGPT) sign-in. The handle comes from the
    /// workspace and user ids (``CodexAccountIdentity``), so it matches the
    /// CodeRouter row of the same sign-in (after the server's legacy-row
    /// migration; see ``CodexAccountIdentity``). When both ids are missing,
    /// `codex:email:<email>` from the token's own email claim is the last
    /// resort (still never a label);
    /// with no email either there is no account. The display is the plan,
    /// else the redacted email, else the provider name.
    func localCodex(_ identity: CodexAccountIdentity, email: String?, plan: String?) -> AccountLabel? {
        let email = email?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let key: String
        if let stable = identity.identity {
            key = stable
        } else if let email {
            key = "codex:email:\(email)"
        } else {
            return nil
        }
        if let reason = identity.instability { CodexAccountIdentity.logUnstable(reason, source: "local") }
        let display = plan?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? email.map(EmailRedaction.redact(identity:)) ?? AIProvider.codex.displayName
        return AccountLabel(handle: handle(namespace: AIProvider.codex.rawValue, identity: key), display: display)
    }

    /// A CodeRouter account row. The handle comes from a stable identity.
    /// Codex: the workspace (`providerAccountId`) and user
    /// (`providerUserId`) ids (``CodexAccountIdentity``), else the row id;
    /// never the label, which the server rewrites and the user can rename.
    /// A legacy Codex row (no `providerUserId` until the server's
    /// `upgradeLegacyCodexIdentity` runs) gets the workspace-only handle.
    /// Other providers: the label only when it is an email, else
    /// `providerAccountId`, else `identifier`, else the row id. A
    /// user-editable label is display only: renaming keeps the handle, and
    /// two rows with the same label keep different handles. The display is
    /// the label, else `identifier`, else `fallback`, with every email
    /// shortened.
    public func server(namespace: String, id: String, label: String?, providerAccountId: String? = nil, providerUserId: String? = nil,
                       identifier: String? = nil, fallback: String = "") -> AccountLabel {
        let label = label?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let accountID = providerAccountId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let identifier = identifier?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let identity: String
        if namespace == AIProvider.codex.rawValue {
            let codex = CodexAccountIdentity(workspaceID: accountID, userID: providerUserId)
            if let reason = codex.instability { CodexAccountIdentity.logUnstable(reason, source: "server row") }
            identity = codex.identity ?? "id:\(id)"
        } else {
            identity = label.flatMap { EmailRedaction.containsEmail($0) ? $0 : nil } ?? accountID ?? identifier ?? "id:\(id)"
        }
        return AccountLabel(handle: handle(namespace: namespace, identity: identity), display: label ?? identifier ?? fallback)
    }

    /// RFC 4648 base32, lowercase, no padding.
    static func base32(_ bytes: some Sequence<UInt8>) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var output = "", buffer: UInt32 = 0, bits = 0
        for byte in bytes {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                output.append(alphabet[Int((buffer >> UInt32(bits - 5)) & 31)])
                bits -= 5
            }
        }
        if bits > 0 { output.append(alphabet[Int((buffer << UInt32(5 - bits)) & 31)]) }
        return output
    }
}
