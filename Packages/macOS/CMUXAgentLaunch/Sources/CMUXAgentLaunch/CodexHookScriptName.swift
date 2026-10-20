import CryptoKit
import Foundation

/// The immutable filename identity of a cmux-generated Codex hook script.
public struct CodexHookScriptName: Equatable, Sendable {
    /// The first eight SHA-256 bytes, or nil for an explicitly recognized legacy filename.
    public let contentID: String?

    /// The filesystem-safe hook event or subcommand represented by the script.
    public let subcommand: String

    /// Builds a filename identity from exact contents, or nil for a separator-only subcommand.
    public init?(contents: String, subcommand: String) {
        let normalizedSubcommand = subcommand.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "-",
            options: .regularExpression
        )
        guard codexHookSubcommandHasIdentity(normalizedSubcommand) else { return nil }

        self.contentID = SHA256.hash(data: Data(contents.utf8))
            .prefix(8)
            .reduce(into: "") { result, byte in
                if byte < 16 { result.append("0") }
                result.append(String(byte, radix: 16))
            }
        self.subcommand = normalizedSubcommand
    }

    /// Parses a canonical content-addressed filename or an explicit cmux legacy filename.
    public init?(filename: String) {
        let prefix = "cmux-codex-hook-"
        let suffix = ".sh"
        guard filename.hasPrefix(prefix), filename.hasSuffix(suffix) else { return nil }

        let body = filename.dropFirst(prefix.count).dropLast(suffix.count)
        if recognizedLegacyCodexHookSubcommands.contains(String(body)) {
            self.contentID = nil
            self.subcommand = String(body)
            return
        }

        guard body.count > 17,
              let contentIDEnd = body.index(body.startIndex, offsetBy: 16, limitedBy: body.endIndex),
              body[contentIDEnd] == "-"
        else {
            return nil
        }

        let contentID = body[..<contentIDEnd]
        let subcommand = body[body.index(after: contentIDEnd)...]
        guard contentID.utf8.allSatisfy(isLowercaseCodexHookHexadecimal),
              subcommand.utf8.allSatisfy(isSafeCodexHookSubcommandCharacter),
              codexHookSubcommandHasIdentity(String(subcommand))
        else {
            return nil
        }

        self.contentID = String(contentID)
        self.subcommand = String(subcommand)
    }

    /// The canonical filename stored under cmux's generated hook directory.
    public var filename: String {
        if let contentID {
            return "cmux-codex-hook-\(contentID)-\(subcommand).sh"
        }
        return "cmux-codex-hook-\(subcommand).sh"
    }
}

private let recognizedLegacyCodexHookSubcommands: Set<String> = [
    "session-start",
    "prompt-submit",
    "user-prompt-submit",
    "stop",
    "session-stop",
    "pre-tool-use",
    "post-tool-use",
    "notification",
    "persistent-session-start",
    "persistent-prompt-submit",
    "persistent-stop",
    "persistent-feed-PreToolUse",
    "persistent-feed-PermissionRequest",
    "persistent-feed-PostToolUse",
    "persistent-feed-PreCompact",
    "persistent-feed-PostCompact",
    "persistent-feed-SubagentStart",
    "persistent-feed-SubagentStop",
    // Transitional wrapper generations emitted the native child events before
    // content-addressed script names were enforced. Keep those paths
    // removable so a captured launch cannot replay stale cmux hooks.
    "subagent-start",
    "subagent-stop",
]

private func isLowercaseCodexHookHexadecimal(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (97...102).contains(byte)
}

private func isSafeCodexHookSubcommandCharacter(_ byte: UInt8) -> Bool {
    (48...57).contains(byte)
        || (65...90).contains(byte)
        || (97...122).contains(byte)
        || byte == 45
        || byte == 95
}

private func codexHookSubcommandHasIdentity(_ subcommand: String) -> Bool {
    subcommand.utf8.contains { byte in
        (48...57).contains(byte)
            || (65...90).contains(byte)
            || (97...122).contains(byte)
    }
}
