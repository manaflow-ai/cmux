/// Preview lines as they leave the Mac: one line, no control characters or
/// escape sequences, at most 400 characters (workspace.schema.json
/// `workspace.preview.set`). Terminal text is untrusted: a preview must never
/// carry bytes the phone's UI would interpret.
public struct MobilePreview: Sendable {
    public static let maxLength = 400

    public let text: String?

    public init(_ raw: String?) {
        guard let raw else { text = nil; return }
        var out = ""
        // 0: text, 1: after ESC, 2: in CSI (ends at 0x40...0x7E), 3: in OSC/DCS (ends at BEL or ESC \).
        var mode = 0
        for scalar in raw.unicodeScalars {
            let v = scalar.value
            switch mode {
            case 1:
                switch v {
                case 0x5B: mode = 2
                case 0x5D, 0x50, 0x5F, 0x5E: mode = 3
                default: mode = 0
                }
                continue
            case 2:
                if (0x40...0x7E).contains(v) { mode = 0 }
                continue
            case 3:
                if v == 0x07 { mode = 0 } else if v == 0x1B { mode = 1 }
                continue
            default:
                break
            }
            switch v {
            case 0x1B: mode = 1
            case 0x09, 0x0A, 0x0D: out.unicodeScalars.append(" ")
            case 0x00...0x1F, 0x7F...0x9F, 0x2028, 0x2029: continue
            default: out.unicodeScalars.append(scalar)
            }
        }
        let trimmed = out.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        text = trimmed.isEmpty ? nil : String(trimmed.prefix(Self.maxLength))
    }
}
