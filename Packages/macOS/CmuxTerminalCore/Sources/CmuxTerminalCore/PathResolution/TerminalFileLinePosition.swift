import Foundation

/// A 1-based line (and optional column) locator peeled off a path token.
///
/// Compilers, `grep -n`, and stack traces print file references as
/// `path:line` or `path:line:column`; this captures the trailing position so
/// cmd-click can forward it to the editor.
public struct TerminalFileLinePosition: Sendable, Equatable {
    public let line: Int
    public let column: Int?

    public init(line: Int, column: Int?) {
        self.line = line
        self.column = column
    }
}

extension String {
    /// Peels a trailing `:line` or `:line:column` locator off the receiver.
    ///
    /// The locator segments must be positive ASCII integers and the remaining
    /// token must be non-empty, so ordinary paths (and `path:` with no number)
    /// are left untouched. Whether the stripped token names a real file is not
    /// checked here — the resolver's existence probe is the real guard, so a
    /// file literally named with a colon still resolves via the literal
    /// candidate.
    ///
    /// - Returns: The token without the locator plus the parsed position, or
    ///   `nil` when there is no numeric locator.
    public func splittingTrailingLineColumn() -> (token: String, position: TerminalFileLinePosition)? {
        func peelNumber(from text: Substring) -> (rest: Substring, value: Int)? {
            guard let colon = text.lastIndex(of: ":") else { return nil }
            let digits = text[text.index(after: colon)...]
            guard !digits.isEmpty,
                  digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(digits), value > 0 else { return nil }
            return (text[..<colon], value)
        }

        guard let last = peelNumber(from: self[...]) else { return nil }

        if let previous = peelNumber(from: last.rest) {
            let token = String(previous.rest)
            guard !token.isEmpty else { return nil }
            return (token, TerminalFileLinePosition(line: previous.value, column: last.value))
        }

        let token = String(last.rest)
        guard !token.isEmpty else { return nil }
        return (token, TerminalFileLinePosition(line: last.value, column: nil))
    }
}

/// Derives the editor line/column locator for a resolved cmd-click target.
public enum TerminalFilePathLineLocator {
    /// The position to open `resolvedPath` at, given the `rawToken` the user
    /// clicked.
    ///
    /// Returns the token's trailing locator, unless the resolved file itself
    /// carries the same numeric suffix (a real filename ending in `:line`), in
    /// which case the digits are part of the name and no position is forwarded.
    public static func position(
        rawToken: String,
        resolvedPath: String
    ) -> TerminalFileLinePosition? {
        guard let (_, position) = rawToken.splittingTrailingLineColumn() else { return nil }
        if let (_, resolvedPosition) = resolvedPath.splittingTrailingLineColumn(),
           resolvedPosition == position {
            return nil
        }
        return position
    }
}
