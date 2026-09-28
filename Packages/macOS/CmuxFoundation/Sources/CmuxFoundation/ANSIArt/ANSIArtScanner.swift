/// Walks the input's scalars, routing printable text to the builder and
/// consuming escape sequences.
struct ANSIArtScanner {
    let scalars: [Unicode.Scalar]
    var builder: ANSIArtBuilder
    private var index = 0

    init(scalars: [Unicode.Scalar], builder: ANSIArtBuilder) {
        self.scalars = scalars
        self.builder = builder
    }

    mutating func scan() {
        while index < scalars.count, !builder.isFull {
            let scalar = scalars[index]
            index += 1
            switch scalar.value {
            case 0x1B:
                consumeEscape()
            case 0x9B:
                consumeControlSequence()
            case 0x90, 0x98, 0x9D, 0x9E, 0x9F:
                // C1 DCS, SOS, OSC, PM and APC carry a string payload.
                consumeControlString()
            case 0x0A:
                builder.newLine()
            case 0x09:
                builder.appendTab()
            case 0x00..<0x20, 0x7F..<0xA0:
                // Other C0/C1 controls (CR, BEL, BS, …) have no place in a
                // still picture.
                continue
            default:
                builder.append(scalar)
            }
        }
    }

    /// Consumes the sequence after an ESC. A byte that cannot continue the
    /// sequence is left for the main loop, so a newline or a new ESC is never
    /// swallowed.
    private mutating func consumeEscape() {
        guard index < scalars.count else { return }
        let value = scalars[index].value
        switch value {
        case 0x5B: // [
            index += 1
            consumeControlSequence()
        case 0x5D, 0x50, 0x58, 0x5E, 0x5F: // ] P X ^ _
            index += 1
            consumeControlString()
        case 0x20...0x2F:
            // nF escapes such as `ESC ( B`: intermediates, then one final byte.
            while index < scalars.count, (0x20...0x2F).contains(scalars[index].value) {
                index += 1
            }
            if index < scalars.count, (0x30...0x7E).contains(scalars[index].value) {
                index += 1
            }
        case 0x30...0x7E:
            index += 1
        default:
            break
        }
    }

    /// Consumes a CSI body. SGR (`m`) styles the text; cursor forward (`C`)
    /// and repeat (`b`), which `chafa` emits to compress runs, place cells.
    /// Every other sequence is dropped.
    private mutating func consumeControlSequence() {
        var parameters = String.UnicodeScalarView()
        var hasIntermediate = false
        var isMalformed = false
        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar.value {
            case 0x30...0x3F:
                // A parameter after an intermediate makes the sequence
                // malformed; keep consuming it so its bytes never print.
                if hasIntermediate { isMalformed = true } else { parameters.append(scalar) }
                index += 1
            case 0x20...0x2F:
                hasIntermediate = true
                index += 1
            case 0x40...0x7E:
                index += 1
                if !hasIntermediate, !isMalformed {
                    apply(final: scalar, parameters: String(parameters))
                }
                return
            case 0x0A, 0x1B:
                // A newline or a new escape ends the sequence and is left
                // for the main loop.
                return
            case 0x00...0x1F, 0x7F:
                // Terminals execute other C0 controls (and ignore DEL)
                // inside a sequence without ending it.
                index += 1
            default:
                return
            }
        }
    }

    private mutating func apply(final: Unicode.Scalar, parameters: String) {
        switch final {
        case "m":
            builder.applySGR(parameters)
        case "C", "b":
            // Private (`?`, `>`, …) forms are other requests.
            guard parameters.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) || $0 == ";" }) else { return }
            let first = parameters.split(separator: ";", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            // A missing or zero count means 1; anything huge is capped by
            // the builder's column limit.
            let count = max(Int(first.prefix(6)) ?? 1, 1)
            if final == "C" {
                builder.appendBlankCells(count)
            } else {
                builder.repeatLastCharacter(count)
            }
        default:
            break
        }
    }

    /// Consumes an OSC/DCS/SOS/PM/APC string through BEL or ST. A bare ESC
    /// also ends it and is left for the main loop.
    private mutating func consumeControlString() {
        while index < scalars.count {
            let value = scalars[index].value
            if value == 0x07 || value == 0x9C {
                index += 1
                return
            }
            if value == 0x1B {
                if index + 1 < scalars.count, scalars[index + 1] == "\\" {
                    index += 2
                }
                return
            }
            index += 1
        }
    }
}
