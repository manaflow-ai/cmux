import CryptoKit
import Foundation

/// The immutable, content-addressed filename of a cmux-generated Codex hook script.
public struct CodexHookScriptName: Equatable, Sendable {
    /// The first eight SHA-256 bytes, rendered as 16 lowercase hexadecimal characters.
    public let contentID: String

    /// The filesystem-safe hook event or subcommand represented by the script.
    public let subcommand: String

    /// Builds a filename identity from the exact script contents and hook subcommand.
    public init(contents: String, subcommand: String) {
        self.contentID = SHA256.hash(data: Data(contents.utf8))
            .prefix(8)
            .reduce(into: "") { result, byte in
                if byte < 16 { result.append("0") }
                result.append(String(byte, radix: 16))
            }
        self.subcommand = subcommand.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "-",
            options: .regularExpression
        )
    }

    /// Parses a canonical content-addressed Codex hook filename.
    public init?(filename: String) {
        let prefix = "cmux-codex-hook-"
        let suffix = ".sh"
        guard filename.hasPrefix(prefix), filename.hasSuffix(suffix) else { return nil }

        let body = filename.dropFirst(prefix.count).dropLast(suffix.count)
        guard body.count > 17,
              let contentIDEnd = body.index(body.startIndex, offsetBy: 16, limitedBy: body.endIndex),
              body[contentIDEnd] == "-"
        else {
            return nil
        }

        let contentID = body[..<contentIDEnd]
        let subcommand = body[body.index(after: contentIDEnd)...]
        guard contentID.utf8.allSatisfy(Self.isLowercaseHexadecimal),
              !subcommand.isEmpty,
              subcommand.utf8.allSatisfy(Self.isSafeSubcommandCharacter)
        else {
            return nil
        }

        self.contentID = String(contentID)
        self.subcommand = String(subcommand)
    }

    /// The canonical filename stored under cmux's generated hook directory.
    public var filename: String {
        "cmux-codex-hook-\(contentID)-\(subcommand).sh"
    }

    private static func isLowercaseHexadecimal(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...102).contains(byte)
    }

    private static func isSafeSubcommandCharacter(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
            || (65...90).contains(byte)
            || (97...122).contains(byte)
            || byte == 45
            || byte == 95
    }
}
