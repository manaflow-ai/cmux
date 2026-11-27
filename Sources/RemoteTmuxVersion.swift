import Foundation

/// Parses `tmux -V` output and decides whether a remote tmux is new enough for
/// `cmux ssh-tmux`.
///
/// **Minimum is tmux 3.2.** Determined empirically (see
/// `docs/investigations/remote-agent-status-sidebar.md` and the version matrix):
/// the live mirror relies on control-mode subscriptions via `refresh-client -B`
/// for per-pane working-directory, foreground-command (reflow + close
/// confirmation), and the `@cmux_agent` / `@cmux_git` status channels. `-B`
/// was added in tmux 3.2 — on 3.1 and older it is an "unknown option", so the
/// mirror would attach but never receive any live pane state, silently. tmux 1.x
/// is worse still: its control mode omits the `%begin`/`%end` command framing the
/// command-correlation FIFO depends on. Rather than mirror into a broken state,
/// cmux asserts the version up front and surfaces a clear error.
struct RemoteTmuxVersion: Equatable, Comparable, Sendable {
    let major: Int
    let minor: Int
    /// Trailing release letter as a 1-based rank (`a` → 1, `b` → 2, …), `0` when
    /// absent. Lets `3.2a` sort after `3.2` without affecting the `>= 3.2` gate.
    let letterRank: Int

    /// The minimum version `cmux ssh-tmux` supports.
    static let minimumSupported = RemoteTmuxVersion(major: 3, minor: 2, letterRank: 0)

    static func < (lhs: RemoteTmuxVersion, rhs: RemoteTmuxVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.letterRank < rhs.letterRank
    }

    var meetsMinimum: Bool { self >= Self.minimumSupported }

    /// Human-readable form, e.g. `3.2a` or `3.4`.
    var displayString: String {
        let letter = letterRank > 0
            ? String(UnicodeScalar(UInt8(96 + letterRank)))  // 1 → 'a'
            : ""
        return "\(major).\(minor)\(letter)"
    }

    /// Parses a `tmux -V` line such as `tmux 3.2a`, `tmux 1.8`, or `tmux 3.1c`.
    ///
    /// Returns `nil` for output with no `tmux` line containing a numeric
    /// `<major>.<minor>` token — e.g. a development build (`tmux master`) or the
    /// OpenBSD-bundled `tmux openbsd-7.x`.
    /// Callers treat an unparseable version as "unknown, allow" rather than
    /// blocking, since a dev/distro build is usually current.
    ///
    /// Note: a string that merely *contains* a `<major>.<minor>` (e.g.
    /// `tmux next-3.4`, a dev build of the upcoming 3.4) on a `tmux` output line
    /// IS parsed — to `3.4` here — and version-checked, not passed through. That's
    /// fine: such builds are at or above the minimum anyway.
    static func parse(_ output: String) -> RemoteTmuxVersion? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed == "tmux" || trimmed.hasPrefix("tmux ") || trimmed.hasPrefix("tmux\t") else {
                continue
            }
            let suffix = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            let versionToken = suffix.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            if let version = parseVersionToken(in: versionToken) {
                return version
            }
        }
        return nil
    }

    /// Parses the server-reported `#{version}` format, e.g. `3.2a`.
    static func parseServerFormat(_ output: String) -> RemoteTmuxVersion? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(whereSeparator: \.isWhitespace)
            guard parts.count == 1 else { continue }
            if let version = parseWholeVersionToken(String(parts[0])) {
                return version
            }
        }
        return nil
    }

    private static func parseWholeVersionToken(_ token: String) -> RemoteTmuxVersion? {
        guard let dot = token.firstIndex(of: "."),
              dot != token.startIndex,
              token.index(after: dot) != token.endIndex else {
            return nil
        }

        let majorPart = token[..<dot]
        var minorEnd = token.index(after: dot)
        while minorEnd < token.endIndex, token[minorEnd].isNumber {
            minorEnd = token.index(after: minorEnd)
        }
        let minorPart = token[token.index(after: dot)..<minorEnd]
        guard !minorPart.isEmpty,
              majorPart.allSatisfy(\.isNumber),
              let major = Int(majorPart),
              let minor = Int(minorPart) else {
            return nil
        }

        var letterRank = 0
        if minorEnd < token.endIndex {
            let afterLetter = token.index(after: minorEnd)
            guard afterLetter == token.endIndex,
                  let ascii = token[minorEnd].asciiValue,
                  ascii >= 97, ascii <= 122 else {
                return nil
            }
            letterRank = Int(ascii) - 96
        }
        return RemoteTmuxVersion(major: major, minor: minor, letterRank: letterRank)
    }

    private static func parseVersionToken(in output: String) -> RemoteTmuxVersion? {
        let scalars = Array(output)
        var i = 0
        while i < scalars.count {
            guard scalars[i].isNumber else { i += 1; continue }
            var j = i
            while j < scalars.count, scalars[j].isNumber { j += 1 }
            guard j < scalars.count, scalars[j] == ".",
                  j + 1 < scalars.count, scalars[j + 1].isNumber else {
                i = j + 1
                continue
            }
            let major = Int(String(scalars[i..<j])) ?? 0
            var k = j + 1
            while k < scalars.count, scalars[k].isNumber { k += 1 }
            let minor = Int(String(scalars[(j + 1)..<k])) ?? 0
            var letterRank = 0
            if k < scalars.count, scalars[k].isLowercase, scalars[k].isLetter,
               let ascii = scalars[k].asciiValue {
                letterRank = Int(ascii) - 96  // 'a' → 1
            }
            return RemoteTmuxVersion(major: major, minor: minor, letterRank: letterRank)
        }
        return nil
    }
}
