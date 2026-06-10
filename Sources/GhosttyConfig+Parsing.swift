import Foundation
import AppKit


// MARK: - Directive Parsing
extension GhosttyConfig {
    mutating func parse(
        _ contents: String,
        loadingThemesImmediatelyFor preferredColorScheme: ColorSchemePreference? = nil
    ) {
        let lines = contents.components(separatedBy: .newlines)
        for line in lines {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            // Strip a leading UTF-8 BOM so a BOM-encoded first line (e.g. a
            // `sidebar-font-size` setting) is still parsed instead of silently
            // ignored, matching `CmuxGhosttyConfigSettingEditor.parsedSetting`.
            if trimmed.hasPrefix("\u{FEFF}") {
                trimmed.removeFirst()
                trimmed = trimmed.trimmingCharacters(in: .whitespaces)
            }
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
                case "surface-tab-bar-font-size":
                    if let size = Double(value), size.isFinite {
                        surfaceTabBarFontSize = Self.clampedSurfaceTabBarFontSize(CGFloat(size))
                    }
                case "sidebar-font-size":
                    if let size = Double(value), size.isFinite {
                        sidebarFontSize = Self.clampedSidebarFontSize(CGFloat(size))
                    }
                case "theme":
                    theme = value
                    if let preferredColorScheme {
                        loadTheme(
                            value,
                            environment: ProcessInfo.processInfo.environment,
                            bundleResourceURL: Bundle.main.resourceURL,
                            preferredColorScheme: preferredColorScheme
                        )
                    }
                case "working-directory":
                    workingDirectory = value
                case "scrollback-limit":
                    if let limit = Self.parseIntegerLiteral(value) {
                        scrollbackLimit = limit
                    }
                case "background":
                    hasBackgroundColorDirective = true
                    if let color = NSColor(hex: value) {
                        backgroundColor = color
                        hasParsedBackgroundColor = true
                    } else {
                        hasParsedBackgroundColor = false
                    }
                case "background-opacity":
                    hasBackgroundOpacityDirective = true
                    if let opacity = Double(value) {
                        backgroundOpacity = min(1.0, max(0.0, opacity))
                        hasParsedBackgroundOpacity = true
                    } else {
                        hasParsedBackgroundOpacity = false
                    }
                case "background-blur":
                    hasBackgroundBlurDirective = true
                    if let parsedBlur = Self.parseBackgroundBlur(value) {
                        backgroundBlur = parsedBlur
                        hasParsedBackgroundBlur = true
                    } else {
                        hasParsedBackgroundBlur = false
                    }
                case "foreground":
                    hasForegroundColorDirective = true
                    if let color = NSColor(hex: value) {
                        foregroundColor = color
                        hasParsedForegroundColor = true
                    } else {
                        hasParsedForegroundColor = false
                    }
                case "cursor-color":
                    hasCursorColorDirective = true
                    if let color = NSColor(hex: value) {
                        cursorColor = color
                        hasParsedCursorColor = true
                    } else {
                        hasParsedCursorColor = false
                    }
                case "cursor-text":
                    hasCursorTextColorDirective = true
                    if let color = NSColor(hex: value) {
                        cursorTextColor = color
                        hasParsedCursorTextColor = true
                    } else {
                        hasParsedCursorTextColor = false
                    }
                case "selection-background":
                    hasSelectionBackgroundDirective = true
                    if let color = NSColor(hex: value) {
                        selectionBackground = color
                        hasParsedSelectionBackground = true
                    } else {
                        hasParsedSelectionBackground = false
                    }
                case "selection-foreground":
                    hasSelectionForegroundDirective = true
                    if let color = NSColor(hex: value) {
                        selectionForeground = color
                        hasParsedSelectionForeground = true
                    } else {
                        hasParsedSelectionForeground = false
                    }
                case "palette":
                    // Parse palette entries like "0=#272822"
                    let paletteParts = value.split(separator: "=", maxSplits: 1)
                    if paletteParts.count == 2,
                       let index = Int(paletteParts[0]),
                       let color = NSColor(hex: String(paletteParts[1])) {
                        palette[index] = color
                    }
                case "unfocused-split-opacity":
                    if let opacity = Double(value) {
                        unfocusedSplitOpacity = opacity
                    }
                case "unfocused-split-fill":
                    if let color = NSColor(hex: value) {
                        unfocusedSplitFill = color
                    }
                case "split-divider-color":
                    if let color = NSColor(hex: value) {
                        splitDividerColor = color
                    }
                case "sidebar-background":
                    rawSidebarBackground = value
                case "sidebar-tint-opacity":
                    if let opacity = Double(value) {
                        sidebarTintOpacity = min(max(opacity, 0), 1)
                    }
                default:
                    break
                }
            }
        }
    }

    private static func parseIntegerLiteral(_ value: String) -> Int? {
        // Strip digit-group separators (for example 10_000_000).
        // Hex and float literals are intentionally unsupported here.
        let normalized = value.replacingOccurrences(of: "_", with: "")
        guard let parsed = Int(normalized), parsed >= 0 else {
            return nil
        }
        return parsed
    }

    static func clampedSidebarFontSize(_ value: CGFloat) -> CGFloat {
        CGFloat(CmuxGhosttyConfigSettingEditor.clampedSidebarFontSize(Double(value)))
    }

    static func clampedSurfaceTabBarFontSize(_ value: CGFloat) -> CGFloat {
        CGFloat(CmuxGhosttyConfigSettingEditor.clampedSurfaceTabBarFontSize(Double(value)))
    }

    private static func parseBackgroundBlur(_ value: String) -> GhosttyBackgroundBlur? {
        switch value {
        case "false", "0":
            return .disabled
        case "true":
            return .radius(20)
        case "macos-glass-regular":
            return .macosGlassRegular
        case "macos-glass-clear":
            return .macosGlassClear
        default:
            guard let radius = parseIntegerLiteral(value), radius > 0, radius <= Int(UInt8.max) else {
                return nil
            }
            return .radius(radius)
        }
    }

}
