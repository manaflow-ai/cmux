/// One classified unit of typed terminal input for local echo prediction.
///
/// The classifier is deliberately conservative, in the mosh tradition of never
/// predicting non-printing input: only single-scalar printable ASCII is ever
/// predicted. Everything else (escape sequences, tabs, wide or combining
/// characters, IME output, C0/C1 controls) is `control`, which the engine
/// treats as an epoch boundary rather than a predictable keystroke.
public enum MobileEchoPredictionInputToken: Equatable, Sendable {
    /// A single-cell printable character the engine may predict.
    case printable(Character)
    /// Backspace (`0x08`) or delete (`0x7F`).
    case backspace
    /// Carriage return or line feed; submits the line, never predicted.
    case lineBreak
    /// Any other input. An escape byte swallows the remainder of its chunk
    /// because escape sequences span multiple characters and predicting their
    /// printable tail (for example the `A` in `ESC [ A`) would corrupt the
    /// overlay.
    case control
}

public enum MobileEchoPredictionInputTokenizer {
    /// Splits one input chunk into prediction tokens.
    ///
    /// Chunks arrive per key event from the ordered input pipeline, so an
    /// escape anywhere in the chunk conservatively classifies the remainder as
    /// one `control` token.
    public static func tokenize(_ text: String) -> [MobileEchoPredictionInputToken] {
        var tokens: [MobileEchoPredictionInputToken] = []
        for character in text {
            if character.unicodeScalars.contains(where: { $0.value == 0x1B }) {
                tokens.append(.control)
                return tokens
            }
            tokens.append(classify(character))
        }
        return tokens
    }

    private static func classify(_ character: Character) -> MobileEchoPredictionInputToken {
        if character == "\u{08}" || character == "\u{7F}" {
            return .backspace
        }
        if character == "\r" || character == "\n" || character == "\r\n" {
            return .lineBreak
        }
        let scalars = character.unicodeScalars
        if scalars.count == 1,
           let scalar = scalars.first,
           (0x20...0x7E).contains(scalar.value) {
            return .printable(character)
        }
        return .control
    }
}
