import Foundation

extension ThemeFileColors {
    /// Ghostty theme-file lines for a base16 scheme (`base00: "1d1f21"`, flat or nested under
    /// `palette:` as tinted-theming writes it), with base16-shell's terminal mapping: background
    /// base00, foreground and cursor base05, selection base02, ANSI 0-7 from base00/08/0B/0A/0D/0E/0C/05
    /// and the brights the same but base03 and base07. Empty when the text has no base16 colors.
    public static func base16ThemeLines(_ text: String) -> [String] {
        var base: [Int: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.lowercased().hasPrefix("base0"), let colon = line.firstIndex(of: ":"),
                  let slot = Int(line[line.index(line.startIndex, offsetBy: 4)..<colon], radix: 16) else { continue }
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let comment = value.range(of: " #") { value = String(value[..<comment.lowerBound]) }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' #"))
            guard value.count == 6, value.allSatisfy(\.isHexDigit) else { continue }
            base[slot] = "#" + value.lowercased()
        }
        let palette = [0x00, 0x08, 0x0B, 0x0A, 0x0D, 0x0E, 0x0C, 0x05, 0x03, 0x08, 0x0B, 0x0A, 0x0D, 0x0E, 0x0C, 0x07]
        let named: [(String, Int)] = [("background", 0x00), ("foreground", 0x05), ("cursor-color", 0x05),
                                      ("cursor-text", 0x00), ("selection-background", 0x02),
                                      ("selection-foreground", 0x05)]
        return named.compactMap { key, slot in base[slot].map { "\(key) = \($0)" } }
            + palette.enumerated().compactMap { index, slot in base[slot].map { "palette = \(index)=\($0)" } }
    }
}
