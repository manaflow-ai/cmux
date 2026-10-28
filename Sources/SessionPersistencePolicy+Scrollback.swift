import Foundation

extension SessionPersistencePolicy {
    static func truncatedScrollback(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let scalars = text.unicodeScalars
        let scalarStart = scalars.index(
            scalars.endIndex, offsetBy: -maxScrollbackScalarsPerTerminal,
            limitedBy: scalars.startIndex
        ) ?? scalars.startIndex
        let boundedSuffix = text[scalarStart...]
        let initialStart = boundedSuffix.count > maxScrollbackCharactersPerTerminal
            ? boundedSuffix.index(boundedSuffix.endIndex, offsetBy: -maxScrollbackCharactersPerTerminal)
            : scalarStart
        // Both budgets choose a boundary in the original string. Its prefix
        // still contains any OSC/DCS introducer needed to skip a cut payload.
        let safeStart = ansiSafeTruncationStart(in: text, initialStart: initialStart)
        return String(text[safeStart...])
    }

    /// If truncation starts in the middle of an ANSI control sequence, advance
    /// past its terminator so replay never begins with a partial escape payload.
    private static let maxAnsiStringSequenceScanCharacters = 1_024

    private static func ansiSafeTruncationStart(in text: String, initialStart: String.Index) -> String.Index {
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

    private static func csiFinalByteIndex(
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

    private static func hasRecentBELTerminator(
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

    private static func ansiStringSequenceEnd(
        in text: String,
        from start: String.Index,
        upperBound: String.Index,
        allowsBEL: Bool
    ) -> String.Index? {
        var index = start
        var scanned = 0
        while index < upperBound, scanned < maxAnsiStringSequenceScanCharacters {
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
