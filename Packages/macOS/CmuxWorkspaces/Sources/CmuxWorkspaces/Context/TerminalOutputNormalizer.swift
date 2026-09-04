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
        /// An opaque DCS/ SOS/ PM/ APC string whose payload is not display text.
        case stringControl
        /// An ESC seen inside an opaque string; only `ESC \` terminates it.
        case stringControlEscape
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
                } else if code == 0x9B { // C1 CSI
                    escapeMode = .csi
                } else if code == 0x9D { // C1 OSC
                    escapeMode = .osc
                } else if code == 0x90 || code == 0x98 || code == 0x9E || code == 0x9F {
                    // C1 DCS, SOS, PM, and APC. These strings are terminated
                    // by ST and their payload must never participate in
                    // provider-marker matching.
                    escapeMode = .stringControl
                } else if code >= 0x20 || code == 0x0A || code == 0x0D || code == 0x09 {
                    result.unicodeScalars.append(scalar)
                }
            case .escape:
                switch code {
                case 0x5B: // CSI
                    escapeMode = .csi
                case 0x5D: // OSC
                    escapeMode = .osc
                case 0x50, 0x58, 0x5E, 0x5F: // DCS, SOS, PM, APC
                    escapeMode = .stringControl
                default:
                    // Two-byte ESC sequences consume this scalar. A later
                    // printable scalar starts a fresh text run.
                    escapeMode = .none
                }
            case .csi:
                if code == 0x9C {
                    escapeMode = .none
                } else if code >= 0x40, code <= 0x7E {
                    escapeMode = .none
                }
            case .osc:
                if code == 0x07 || code == 0x9C { // BEL or C1 ST
                    escapeMode = .none
                } else if code == 0x1B {
                    escapeMode = .oscEscape
                }
            case .oscEscape:
                escapeMode = code == 0x5C || code == 0x9C ? .none : .osc
            case .stringControl:
                if code == 0x9C { // C1 ST
                    escapeMode = .none
                } else if code == 0x1B {
                    escapeMode = .stringControlEscape
                }
            case .stringControlEscape:
                // String controls terminate with ST (`ESC \\`) or C1 ST.
                // Any other escaped byte remains opaque string payload.
                escapeMode = code == 0x5C || code == 0x9C
                    ? .none
                    : .stringControl
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
