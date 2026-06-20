public import Foundation

/// Raw terminal-text reads captured from a Ghostty surface, one optional field
/// per Ghostty point tag.
///
/// The app target fills these from `ghostty_surface_read_text` (the
/// engine-coupled read path stays app-side); the pure payload assembly in
/// ``TerminalTextPayload/make(from:includeScrollback:lineLimit:)`` turns a
/// snapshot into the wire payload without touching the engine.
public struct TerminalTextRawSnapshot: Sendable, Equatable {
    /// Visible viewport text (non-scrollback reads).
    public var viewport: String?
    /// Full on-screen text (`GHOSTTY_POINT_SCREEN`).
    public var screen: String?
    /// Scrollback history text (`GHOSTTY_POINT_SURFACE`).
    public var history: String?
    /// Active-area text (`GHOSTTY_POINT_ACTIVE`).
    public var active: String?

    /// Creates a raw snapshot from the four optional per-point reads.
    public init(
        viewport: String? = nil,
        screen: String? = nil,
        history: String? = nil,
        active: String? = nil
    ) {
        self.viewport = viewport
        self.screen = screen
        self.history = history
        self.active = active
    }
}

/// A failure assembling a ``TerminalTextPayload`` from a snapshot.
public struct TerminalTextPayloadError: Error, Equatable, Sendable {
    /// The user-facing failure message, carried verbatim onto the wire.
    public let message: String

    /// Creates a payload error carrying `message`.
    public init(message: String) {
        self.message = message
    }
}

/// The assembled terminal-text wire payload: the chosen text and its base64
/// encoding.
public struct TerminalTextPayload: Equatable, Sendable {
    /// The selected terminal text (already tailed to `lineLimit` when requested).
    public let text: String
    /// `text` encoded as base64 (empty string if UTF-8 encoding fails, matching
    /// legacy behavior).
    public let base64: String

    /// Creates a payload from already-assembled text and its base64 encoding.
    public init(text: String, base64: String) {
        self.text = text
        self.base64 = base64
    }

    /// Assembles the wire payload from a raw snapshot, picking the best
    /// scrollback candidate (most lines, then most bytes) when scrollback is
    /// requested, or the viewport otherwise, applying `lineLimit` tailing.
    ///
    /// Byte-faithful relocation of the former `TerminalController.terminalTextPayload`.
    public static func make(
        from snapshot: TerminalTextRawSnapshot,
        includeScrollback: Bool,
        lineLimit: Int?
    ) -> Result<TerminalTextPayload, TerminalTextPayloadError> {
        let output: String
        if includeScrollback {
            var candidates: [String] = []
            if let screen = snapshot.screen {
                candidates.append(lineLimit.map { screen.terminalTextTail(maxLines: $0) } ?? screen)
            }
            if snapshot.history != nil || snapshot.active != nil {
                var merged = lineLimit.map {
                    (snapshot.history ?? "").terminalTextTail(maxLines: $0)
                } ?? (snapshot.history ?? "")
                if let active = snapshot.active {
                    if !merged.isEmpty, !merged.hasSuffix("\n"), !active.isEmpty {
                        merged.append("\n")
                    }
                    merged.append(lineLimit.map { active.terminalTextTail(maxLines: $0) } ?? active)
                }
                candidates.append(lineLimit.map { merged.terminalTextTail(maxLines: $0) } ?? merged)
            }

            guard let best = candidates.max(by: { lhs, rhs in
                let left = lhs.terminalTextCandidateScore
                let right = rhs.terminalTextCandidateScore
                if left.lines != right.lines {
                    return left.lines < right.lines
                }
                return left.bytes < right.bytes
            }) else {
                return .failure(TerminalTextPayloadError(message: "Failed to read terminal text"))
            }
            output = best
        } else {
            guard var viewport = snapshot.viewport else {
                return .failure(TerminalTextPayloadError(message: "Failed to read terminal text"))
            }
            if let lineLimit {
                viewport = viewport.terminalTextTail(maxLines: lineLimit)
            }
            output = viewport
        }

        let base64 = output.data(using: .utf8)?.base64EncodedString() ?? ""
        return .success(TerminalTextPayload(text: output, base64: base64))
    }
}

extension String {
    /// Returns the trailing `maxLines` newline-delimited lines, preserving the
    /// original trailing-newline semantics (a CRLF counts as one character, so
    /// it is never split mid-pair, matching the legacy reverse-scan).
    ///
    /// Byte-faithful relocation of the former `TerminalController.tailTerminalLines`.
    public func terminalTextTail(maxLines: Int) -> String {
        guard maxLines > 0 else { return "" }
        var newlineCount = 0
        var index = endIndex
        while index > startIndex {
            let previous = self.index(before: index)
            if self[previous] == "\n" {
                newlineCount += 1
                if newlineCount == maxLines {
                    return String(self[index...])
                }
            }
            index = previous
        }
        return self
    }

    /// The candidate ranking score for scrollback selection: `(lines, bytes)`,
    /// where `lines` is the UTF-8 newline count plus one (zero for empty text)
    /// and `bytes` is the UTF-8 length.
    ///
    /// Byte-faithful relocation of the former
    /// `TerminalController.terminalTextCandidateScore`.
    fileprivate var terminalTextCandidateScore: (lines: Int, bytes: Int) {
        if isEmpty { return (0, 0) }
        var newlineCount = 0
        var byteCount = 0
        for byte in utf8 {
            byteCount += 1
            if byte == 0x0A {
                newlineCount += 1
            }
        }
        return (newlineCount + 1, byteCount)
    }
}
