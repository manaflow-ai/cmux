import Foundation

extension SessionPersistencePolicy {
    static func truncatedScrollback(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let scalars = text.unicodeScalars
        let scalarStart = scalars.index(
            scalars.endIndex, offsetBy: -maxScrollbackScalarsPerTerminal,
            limitedBy: scalars.startIndex
        ) ?? scalars.startIndex
        // Scan the scalar view so the cut can land inside a grapheme cluster
        // without ever using that scalar index as a String.Index. A String
        // slice must still be formed only from indices valid for its view.
        let ansiScalarStart = ansiSafeScalarTruncationStart(in: text, initialStart: scalarStart)
        let boundedSuffix = String(scalars[ansiScalarStart...])
        let initialStart = boundedSuffix.count > maxScrollbackCharactersPerTerminal
            ? boundedSuffix.index(boundedSuffix.endIndex, offsetBy: -maxScrollbackCharactersPerTerminal)
            : boundedSuffix.startIndex
        let safeStart = ansiSafeTruncationStart(in: boundedSuffix, initialStart: initialStart)
        return String(boundedSuffix[safeStart...])
    }

    private static func ansiSafeScalarTruncationStart(
        in text: String,
        initialStart: String.UnicodeScalarView.Index
    ) -> String.UnicodeScalarView.Index {
        let scalars = text.unicodeScalars
        guard initialStart > scalars.startIndex else { return initialStart }
        var lastEscape: String.UnicodeScalarView.Index?
        var index = scalars.startIndex
        while index < initialStart {
            if scalars[index].value == 0x1B { lastEscape = index }
            index = scalars.index(after: index)
        }
        guard let lastEscape else { return initialStart }
        let marker = scalars.index(after: lastEscape)
        guard marker < scalars.endIndex else { return initialStart }

        switch scalars[marker].value {
        case 0x5B: // CSI
            if scalarCSIFinalByteIndex(in: scalars, from: marker, upperBound: initialStart) != nil {
                return initialStart
            }
            guard let final = scalarCSIFinalByteIndex(
                in: scalars, from: marker, upperBound: scalars.endIndex
            ) else { return initialStart }
            return scalars.index(after: final)
        case 0x5D, 0x50, 0x58, 0x5F, 0x5E: // OSC, DCS, SOS, APC, PM
            let allowsBEL = scalars[marker].value == 0x5D
            if allowsBEL,
               scalarStringSequenceEnd(
                   in: scalars, from: scalars.index(after: marker),
                   upperBound: initialStart, allowsBEL: true
               ) != nil {
                return initialStart
            }
            return scalarStringSequenceEnd(
                in: scalars, from: initialStart,
                upperBound: scalars.endIndex, allowsBEL: allowsBEL
            ) ?? initialStart
        case 0x5C: // ST, with the cut on its second byte
            return marker == initialStart ? scalars.index(after: marker) : initialStart
        default:
            return initialStart
        }
    }

    private static func scalarCSIFinalByteIndex(
        in scalars: String.UnicodeScalarView,
        from marker: String.UnicodeScalarView.Index,
        upperBound: String.UnicodeScalarView.Index
    ) -> String.UnicodeScalarView.Index? {
        var index = scalars.index(after: marker)
        while index < upperBound {
            let value = scalars[index].value
            if value >= 0x40, value <= 0x7E { return index }
            index = scalars.index(after: index)
        }
        return nil
    }

    private static func scalarStringSequenceEnd(
        in scalars: String.UnicodeScalarView,
        from start: String.UnicodeScalarView.Index,
        upperBound: String.UnicodeScalarView.Index,
        allowsBEL: Bool
    ) -> String.UnicodeScalarView.Index? {
        var index = start
        var scanned = 0
        while index < upperBound, scanned < maxAnsiStringSequenceScanCharacters {
            if allowsBEL, scalars[index].value == 0x07 {
                return scalars.index(after: index)
            }
            if scalars[index].value == 0x1B {
                let next = scalars.index(after: index)
                if next < upperBound, scalars[next].value == 0x5C {
                    return scalars.index(after: next)
                }
            }
            index = scalars.index(after: index)
            scanned += 1
        }
        return nil
    }

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
        while index < upperBound {
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
        }
        return nil
    }
}
