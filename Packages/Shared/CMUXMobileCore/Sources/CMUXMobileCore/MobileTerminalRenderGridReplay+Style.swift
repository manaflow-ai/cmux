import Foundation

extension MobileTerminalRenderGridReplay {
    func sgrBytes(for style: MobileTerminalRenderGridFrame.Style) -> Data {
        var codes = ["0"]
        if style.bold { codes.append("1") }
        if style.faint { codes.append("2") }
        if style.italic { codes.append("3") }
        if style.underline { codes.append("4") }
        if style.blink { codes.append("5") }
        if style.inverse { codes.append("7") }
        if style.invisible { codes.append("8") }
        if style.strikethrough { codes.append("9") }
        if style.overline { codes.append("53") }
        if style.foregroundSource == .defaultColor {
            codes.append("39")
        } else if style.foregroundSource == .palette,
                  let index = style.foregroundPaletteIndex,
                  (0...255).contains(index) {
            codes.append("38;5;\(index)")
        } else if let foreground = rgbComponents(style.foreground) {
            codes.append("38;2;\(foreground.red);\(foreground.green);\(foreground.blue)")
        }
        if style.backgroundSource == .defaultColor {
            codes.append("49")
        } else if style.backgroundSource == .palette,
                  let index = style.backgroundPaletteIndex,
                  (0...255).contains(index) {
            codes.append("48;5;\(index)")
        } else if let background = rgbComponents(style.background) {
            codes.append("48;2;\(background.red);\(background.green);\(background.blue)")
        }
        return Data("\u{1B}[\(codes.joined(separator: ";"))m".utf8)
    }

    func rgbComponents(_ value: String?) -> (red: Int, green: Int, blue: Int)? {
        guard var value else { return nil }
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        guard value.count == 6, let raw = Int(value, radix: 16) else { return nil }
        return ((raw >> 16) & 0xFF, (raw >> 8) & 0xFF, raw & 0xFF)
    }
}
