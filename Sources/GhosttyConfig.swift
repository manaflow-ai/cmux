import Foundation
import AppKit

struct GhosttyConfig {
    var fontFamily: String = "Menlo"
    var fontSize: CGFloat = 12
    var theme: String?
    var workingDirectory: String?
    var scrollbackLimit: Int = 10000

    // Colors (from theme or config)
    var backgroundColor: NSColor = NSColor(hex: "#272822")!
    var foregroundColor: NSColor = NSColor(hex: "#fdfff1")!
    var cursorColor: NSColor = NSColor(hex: "#c0c1b5")!
    var cursorTextColor: NSColor = NSColor(hex: "#8d8e82")!
    var selectionBackground: NSColor = NSColor(hex: "#57584f")!
    var selectionForeground: NSColor = NSColor(hex: "#fdfff1")!

    // Palette colors (0-15)
    var palette: [Int: NSColor] = [:]

    static func load() -> GhosttyConfig {
        var config = GhosttyConfig()

        // Load user config
        let configPath = NSString(string: "~/Library/Application Support/com.mitchellh.ghostty/config").expandingTildeInPath
        if let contents = try? String(contentsOfFile: configPath, encoding: .utf8) {
            config.parse(contents)
        }

        // Load theme if specified
        if let themeName = config.theme {
            config.loadTheme(themeName)
        }

        return config
    }

    mutating func parse(_ contents: String) {
        let lines = contents.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            let parts = trimmed.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))

                switch key {
                case "font-family":
                    fontFamily = value
                case "font-size":
                    if let size = Double(value) {
                        fontSize = CGFloat(size)
                    }
                case "theme":
                    theme = value
                case "working-directory":
                    workingDirectory = value
                case "scrollback-limit":
                    if let limit = Int(value) {
                        scrollbackLimit = limit
                    }
                case "background":
                    if let color = NSColor(hex: value) {
                        backgroundColor = color
                    }
                case "foreground":
                    if let color = NSColor(hex: value) {
                        foregroundColor = color
                    }
                case "cursor-color":
                    if let color = NSColor(hex: value) {
                        cursorColor = color
                    }
                case "cursor-text":
                    if let color = NSColor(hex: value) {
                        cursorTextColor = color
                    }
                case "selection-background":
                    if let color = NSColor(hex: value) {
                        selectionBackground = color
                    }
                case "selection-foreground":
                    if let color = NSColor(hex: value) {
                        selectionForeground = color
                    }
                case "palette":
                    // Parse palette entries like "0=#272822"
                    let paletteParts = value.split(separator: "=", maxSplits: 1)
                    if paletteParts.count == 2,
                       let index = Int(paletteParts[0]),
                       let color = NSColor(hex: String(paletteParts[1])) {
                        palette[index] = color
                    }
                default:
                    break
                }
            }
        }
    }

    mutating func loadTheme(_ name: String) {
        // Try to load from Ghostty app resources
        let themePaths = [
            "/Applications/Ghostty.app/Contents/Resources/ghostty/themes/\(name)",
            NSString(string: "~/.config/ghostty/themes/\(name)").expandingTildeInPath
        ]

        for path in themePaths {
            if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
                parse(contents)
                return
            }
        }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else {
            return nil
        }

        let r, g, b: CGFloat
        if hexSanitized.count == 6 {
            r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
            g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
            b = CGFloat(rgb & 0x0000FF) / 255.0
        } else {
            return nil
        }

        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}
