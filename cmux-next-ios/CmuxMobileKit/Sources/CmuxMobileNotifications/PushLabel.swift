import Foundation

/// Compares an option label a notification showed with the Mac's own label
/// (PR #24156 review M1). The host and the Worker clean a label the same way
/// (control and format characters become spaces, whitespace runs one space,
/// combining marks past two dropped) and cut a long one with "…", so the
/// label the person saw matches the live one when the live one, cleaned the
/// same way, is equal to it or starts with what precedes the "…".
public struct PushLabel: Sendable {
    public init() {}

    public static func normalize(_ text: String) -> String {
        var marks = 0
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.properties.generalCategory == .nonspacingMark {
                marks += 1
                if marks <= 2 { out.append(scalar) }
                continue
            }
            marks = 0
            let hidden = scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format
                || scalar.properties.generalCategory == .lineSeparator || scalar.properties.generalCategory == .paragraphSeparator
            out.append(hidden ? " " : scalar)
        }
        return String(out).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func matches(sent: String, live: String) -> Bool {
        let sent = normalize(sent)
        let live = normalize(live)
        guard !sent.isEmpty else { return false }
        if sent == live { return true }
        guard sent.hasSuffix("…") else { return false }
        let prefix = sent.dropLast().trimmingCharacters(in: .whitespaces)
        return !prefix.isEmpty && live.hasPrefix(prefix)
    }
}
