/// One screen line as characters with the faint attribute each was drawn in.
struct AgentPromptStyledLine: Equatable {
    struct Cell: Equatable {
        let character: Character
        let isFaint: Bool
    }

    var cells: [Cell] = []

    func startsWithGlyph(_ glyph: Character) -> Bool {
        cells.first { !AgentPromptInputReader.isBlank($0.character) }?.character == glyph
    }

    /// A line drawn only from box-drawing horizontals, like the rules around
    /// Claude Code's input.
    var isHorizontalRule: Bool {
        let visible = cells.filter { !$0.character.isWhitespace }
        return !visible.isEmpty && visible.allSatisfy { $0.character == "─" }
    }

    /// Splits VT text into lines, tracking SGR faint across the whole capture
    /// the way a terminal would. Other escape sequences are skipped.
    static func parse(_ text: String) -> [AgentPromptStyledLine] {
        var lines: [AgentPromptStyledLine] = [AgentPromptStyledLine()]
        var isFaint = false
        var iterator = Array(text.unicodeScalars)[...]
        var pending = String.UnicodeScalarView()

        func flushPending() {
            guard !pending.isEmpty else { return }
            for character in String(pending) {
                lines[lines.count - 1].cells.append(Cell(character: character, isFaint: isFaint))
            }
            pending = String.UnicodeScalarView()
        }

        while let scalar = iterator.popFirst() {
            switch scalar {
            case "\u{1B}":
                flushPending()
                guard let introducer = iterator.popFirst() else { break }
                switch introducer {
                case "[":
                    var parameters = ""
                    while let next = iterator.popFirst() {
                        if (0x40...0x7E).contains(next.value) {
                            if next == "m" { applySGR(parameters, faint: &isFaint) }
                            break
                        }
                        parameters.unicodeScalars.append(next)
                    }
                case "]", "P", "_", "^":
                    // String sequences end at BEL or ST (ESC \).
                    while let next = iterator.popFirst() {
                        if next == "\u{07}" { break }
                        if next == "\u{1B}", iterator.first == "\\" {
                            iterator.removeFirst()
                            break
                        }
                    }
                case "(", ")", "*", "+":
                    _ = iterator.popFirst()
                default:
                    break
                }
            case "\n":
                flushPending()
                lines.append(AgentPromptStyledLine())
            case "\r":
                flushPending()
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F { continue }
                pending.append(scalar)
            }
        }
        flushPending()
        return lines
    }

    private static func applySGR(_ parameters: String, faint: inout Bool) {
        let raw = parameters.split(separator: ";", omittingEmptySubsequences: false)
        let codes = raw.map { Int($0.split(separator: ":").first ?? "") ?? 0 }
        var index = 0
        while index < codes.count {
            switch codes[index] {
            case 0, 22: faint = false
            case 2: faint = true
            case 38, 48, 58:
                // Extended colors carry their own arguments: 5;n or 2;r;g;b.
                // The colon form keeps them inside this parameter.
                guard !raw[index].contains(":"), index + 1 < codes.count else { break }
                index += codes[index + 1] == 5 ? 2 : codes[index + 1] == 2 ? 4 : 0
            default: break
            }
            index += 1
        }
    }
}
