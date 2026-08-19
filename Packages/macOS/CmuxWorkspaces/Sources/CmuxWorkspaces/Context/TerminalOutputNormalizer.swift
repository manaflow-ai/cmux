/// Strips terminal control sequences while preserving text split across PTY chunks.
struct TerminalOutputNormalizer: Sendable {
    private var escapeMode: EscapeMode = .none
    private var previousWasWhitespace = false

    private enum EscapeMode: Sendable {
        case none
        case escape
        case csi
        case osc
        case oscEscape
    }

    mutating func normalize(_ value: String) -> String {
        var result = String()
        result.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            let code = scalar.value
            switch escapeMode {
            case .none:
                if code == 0x1B {
                    escapeMode = .escape
                } else if code >= 0x20 || code == 0x0A || code == 0x0D || code == 0x09 {
                    result.unicodeScalars.append(scalar)
                }
            case .escape:
                switch code {
                case 0x5B: // CSI
                    escapeMode = .csi
                case 0x5D: // OSC
                    escapeMode = .osc
                default:
                    // Two-byte ESC sequences consume this scalar. A later
                    // printable scalar starts a fresh text run.
                    escapeMode = .none
                }
            case .csi:
                if code >= 0x40, code <= 0x7E {
                    escapeMode = .none
                }
            case .osc:
                if code == 0x07 {
                    escapeMode = .none
                } else if code == 0x1B {
                    escapeMode = .oscEscape
                }
            case .oscEscape:
                escapeMode = code == 0x5C ? .none : .osc
            }
        }
        return normalizeWhitespace(result)
    }

    mutating func reset() {
        escapeMode = .none
        previousWasWhitespace = false
    }

    private mutating func normalizeWhitespace(_ value: String) -> String {
        var result = String()
        for scalar in value.unicodeScalars {
            if scalar.properties.isWhitespace {
                if !previousWasWhitespace {
                    result.append(" ")
                }
                previousWasWhitespace = true
            } else {
                result.unicodeScalars.append(scalar)
                previousWasWhitespace = false
            }
        }
        return result.lowercased()
    }
}
