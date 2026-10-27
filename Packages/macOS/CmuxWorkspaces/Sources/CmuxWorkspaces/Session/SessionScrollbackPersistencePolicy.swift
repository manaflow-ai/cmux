/// Bounds one terminal's scrollback for a session snapshot.
///
/// The line tail, the character cap, and ANSI-safe clipping are pure text
/// rules. Capture, replay files, and snapshot Codable types stay in the app.
/// A fresh capture that fits both caps clears any earlier truncation marker.
///
/// ```swift
/// let persisted = SessionScrollbackPersistencePolicy().persistedScrollback(captured)
/// let stored = persisted.text
/// let wasTruncated = persisted.wasTruncated
/// ```
public struct SessionScrollbackPersistencePolicy: Equatable, Sendable {
    /// Lines kept for one terminal in a session snapshot.
    ///
    /// The bound is the newest lines. The user-facing restore notice quotes
    /// this number.
    public static let sessionSnapshotMaxLines = 4_000

    /// Characters kept for one terminal after the line tail.
    ///
    /// The user-facing restore notice quotes this number. Clipping stays
    /// outside an ANSI control sequence so replay does not start mid-escape.
    public static let sessionSnapshotMaxCharacters = 400_000

    /// The most lines ``tailLines(_:maxLines:)`` retains for this policy.
    public let maxLines: Int

    /// The most characters ``truncatedScrollback(_:)`` retains for this policy.
    public let maxCharacters: Int

    /// How far an unterminated ANSI string sequence is scanned past the cut.
    private static let maxAnsiStringSequenceScanCharacters = 1_024

    /// Creates a policy.
    ///
    /// - Parameters:
    ///   - maxLines: The most lines to retain. Defaults to
    ///     ``sessionSnapshotMaxLines``. Negative values are treated as zero.
    ///   - maxCharacters: The most characters to retain after the line tail.
    ///     Defaults to ``sessionSnapshotMaxCharacters``. Negative values are
    ///     treated as zero.
    public init(
        maxLines: Int = SessionScrollbackPersistencePolicy.sessionSnapshotMaxLines,
        maxCharacters: Int = SessionScrollbackPersistencePolicy.sessionSnapshotMaxCharacters
    ) {
        self.maxLines = max(0, maxLines)
        self.maxCharacters = max(0, maxCharacters)
    }

    /// Keeps the newest `maxLines` lines of `text`.
    ///
    /// A non-positive limit returns an empty string. Fewer lines than the
    /// limit returns `text` unchanged. The cut is after a newline, so the
    /// result does not start with a partial line.
    ///
    /// - Parameters:
    ///   - text: Terminal text, including scrollback.
    ///   - maxLines: How many trailing lines to keep.
    /// - Returns: The trailing lines.
    public func tailLines(_ text: String, maxLines: Int) -> String {
        guard maxLines > 0 else { return "" }
        var newlineCount = 0
        var index = text.endIndex
        while index > text.startIndex {
            let previous = text.index(before: index)
            if text[previous] == "\n" {
                newlineCount += 1
                if newlineCount == maxLines {
                    return String(text[index...])
                }
            }
            index = previous
        }
        return text
    }

    /// Keeps the newest ``maxCharacters`` of `text`, moving the cut past a
    /// partial ANSI sequence.
    ///
    /// - Parameter text: Terminal text. Empty text is not stored.
    /// - Returns: The bounded tail, or nil when there is nothing to store.
    public func truncatedScrollback(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        if text.count <= maxCharacters {
            return text
        }
        let initialStart = text.index(text.endIndex, offsetBy: -maxCharacters)
        let safeStart = ansiSafeTruncationStart(in: text, initialStart: initialStart)
        return String(text[safeStart...])
    }

    /// Applies the line tail and the character cap, and reports whether older
    /// output was dropped.
    ///
    /// - Parameter text: A fresh capture or a stored fallback. Empty text is
    ///   not stored and is not marked truncated.
    /// - Returns: The bounded tail and whether either cap dropped older output.
    public func persistedScrollback(_ text: String?) -> SessionPersistedScrollback {
        guard let text, !text.isEmpty else {
            return SessionPersistedScrollback(text: nil, wasTruncated: false)
        }
        let tailed = tailLines(text, maxLines: maxLines)
        let lineTruncated = tailed.count != text.count
        guard let bounded = truncatedScrollback(tailed) else {
            return SessionPersistedScrollback(text: nil, wasTruncated: lineTruncated)
        }
        return SessionPersistedScrollback(
            text: bounded,
            wasTruncated: lineTruncated || bounded.count != tailed.count
        )
    }

    /// Prefers a fresh capture over fallback scrollback.
    ///
    /// A capture that fits both caps returns `wasTruncated == false`, which
    /// clears a marker carried by the fallback. When the capture is empty, a
    /// fallback that was already truncated stays marked even if its text now
    /// fits the caps.
    ///
    /// - Parameters:
    ///   - capturedScrollback: The live terminal capture, when one was taken.
    ///   - fallbackScrollback: Scrollback remembered from an earlier restore.
    ///   - fallbackWasTruncated: Whether that remembered tail dropped older
    ///     output. Ignored when a capture supplies text.
    ///   - allowFallbackScrollback: When false, an empty capture stores
    ///     nothing instead of the fallback.
    /// - Returns: One value carrying the text to store and its truncation state.
    public func persistedSnapshotScrollback(
        capturedScrollback: String?,
        fallbackScrollback: String?,
        fallbackWasTruncated: Bool = false,
        allowFallbackScrollback: Bool = true
    ) -> SessionPersistedScrollback {
        let captured = persistedScrollback(capturedScrollback)
        if captured.text != nil {
            return captured
        }
        guard allowFallbackScrollback else {
            return SessionPersistedScrollback(text: nil, wasTruncated: false)
        }
        let fallback = persistedScrollback(fallbackScrollback)
        guard let text = fallback.text else {
            return SessionPersistedScrollback(text: nil, wasTruncated: false)
        }
        return SessionPersistedScrollback(
            text: text,
            wasTruncated: fallback.wasTruncated || fallbackWasTruncated
        )
    }

    /// If truncation starts in the middle of an ANSI control sequence, advance
    /// past its terminator so replay never begins with a partial escape payload.
    private func ansiSafeTruncationStart(in text: String, initialStart: String.Index) -> String.Index {
        guard initialStart > text.startIndex else { return initialStart }
        let escape = "\u{001B}"

        guard let lastEscape = text[..<initialStart].lastIndex(of: Character(escape)) else {
            return initialStart
        }
        let marker = text.index(after: lastEscape)
        guard marker < text.endIndex else { return initialStart }

        switch text[marker] {
        case "[":
            // If a final CSI byte exists before the truncation boundary, we are
            // not inside a partial sequence.
            if csiFinalByteIndex(in: text, from: marker, upperBound: initialStart) != nil {
                return initialStart
            }
            guard let final = csiFinalByteIndex(
                in: text,
                from: marker,
                upperBound: text.endIndex
            ) else {
                return initialStart
            }
            let next = text.index(after: final)
            return next < text.endIndex ? next : text.endIndex

        case "]", "P", "X", "_", "^":
            let allowsBEL = text[marker] == "]"
            if allowsBEL,
               hasRecentBELTerminator(
                   in: text,
                   after: marker,
                   before: initialStart
               ) {
                return initialStart
            }
            if allowsBEL,
               ansiStringSequenceEnd(
                   in: text,
                   from: text.index(after: marker),
                   upperBound: initialStart,
                   allowsBEL: true
               ) != nil {
                return initialStart
            }
            return ansiStringSequenceEnd(
                in: text,
                from: initialStart,
                upperBound: text.endIndex,
                allowsBEL: allowsBEL
            ) ?? initialStart

        case "\\":
            // The cut itself can land on the second byte of an ST terminator.
            guard marker == initialStart else { return initialStart }
            let next = text.index(after: marker)
            return next < text.endIndex ? next : text.endIndex

        default:
            return initialStart
        }
    }

    private func csiFinalByteIndex(
        in text: String,
        from csiMarker: String.Index,
        upperBound: String.Index
    ) -> String.Index? {
        var index = text.index(after: csiMarker)
        while index < upperBound {
            guard let scalar = text[index].unicodeScalars.first?.value else {
                index = text.index(after: index)
                continue
            }
            if scalar >= 0x40, scalar <= 0x7E {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }

    private func hasRecentBELTerminator(
        in text: String,
        after marker: String.Index,
        before boundary: String.Index
    ) -> Bool {
        var index = marker
        while index < boundary {
            if text[index] == "\u{0007}" {
                return true
            }
            index = text.index(after: index)
        }
        return false
    }

    private func ansiStringSequenceEnd(
        in text: String,
        from start: String.Index,
        upperBound: String.Index,
        allowsBEL: Bool
    ) -> String.Index? {
        var index = start
        var scanned = 0
        while index < upperBound, scanned < Self.maxAnsiStringSequenceScanCharacters {
            if allowsBEL, text[index] == "\u{0007}" {
                return text.index(after: index)
            }
            if text[index] == "\u{001B}" {
                let next = text.index(after: index)
                if next < upperBound, text[next] == "\\" {
                    return text.index(after: next)
                }
            }
            index = text.index(after: index)
            scanned += 1
        }
        return nil
    }
}
