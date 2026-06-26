public import Foundation

/// Reads and writes cmux's editable Ghostty config settings, including range
/// clamping, display formatting, and symlink-aware writes for font controls.
///
/// TRANSITIONAL: faithful lift of the app-target config-setting-editor namespace
/// that ``GhosttyConfig`` and the settings UI share. Stateless config-body
/// transforms over `String`/`URL` with no single natural receiver; modernization
/// into an instantiated editor is deferred to the engine lift.
public struct CmuxGhosttyConfigSettingEditor {
    /// The config key for the terminal font family.
    public static let terminalFontFamilyKey = "font-family"
    /// The default terminal font family.
    public static let defaultTerminalFontFamily = "Menlo"
    /// The config key for the terminal font size.
    public static let terminalFontSizeKey = "font-size"
    /// The default terminal font size in points.
    public static let defaultTerminalFontSize = 12.0
    /// The smallest terminal font size cmux allows from Settings.
    public static let minTerminalFontSize = 6.0
    /// The largest terminal font size cmux allows from Settings.
    public static let maxTerminalFontSize = 72.0

    /// The config key for the sidebar font size.
    public static let sidebarFontSizeKey = "sidebar-font-size"
    /// The default sidebar font size in points.
    public static let defaultSidebarFontSize = 12.5
    /// The smallest sidebar font size cmux allows.
    public static let minSidebarFontSize = 10.0
    /// The largest sidebar font size cmux allows.
    public static let maxSidebarFontSize = 20.0

    /// The config key for the surface-tab-bar font size.
    public static let surfaceTabBarFontSizeKey = "surface-tab-bar-font-size"
    /// The default surface-tab-bar font size in points.
    public static let defaultSurfaceTabBarFontSize = 11.0
    /// The smallest surface-tab-bar font size cmux allows.
    public static let minSurfaceTabBarFontSize = 8.0
    /// The largest surface-tab-bar font size cmux allows.
    public static let maxSurfaceTabBarFontSize = 14.0

    public init() {}

    /// Clamps a terminal font size to its allowed range, substituting the default
    /// for non-finite input.
    public func clampedTerminalFontSize(_ value: Double) -> Double {
        guard value.isFinite else { return Self.defaultTerminalFontSize }
        return min(max(value, Self.minTerminalFontSize), Self.maxTerminalFontSize)
    }

    /// The clamped terminal font size formatted for display.
    public func formattedTerminalFontSize(_ value: Double) -> String {
        formattedFontSize(clampedTerminalFontSize(value))
    }

    /// The clamped terminal font size parsed from a Ghostty config body, or
    /// `nil` when absent.
    public func parsedTerminalFontSize(in contents: String) -> Double? {
        parsedFontSize(in: contents, key: Self.terminalFontSizeKey, clamp: clampedTerminalFontSize)
    }

    /// The last configured terminal font family in a Ghostty config body, or
    /// `nil` when absent.
    public func parsedTerminalFontFamily(in contents: String) -> String? {
        parsedValue(for: Self.terminalFontFamilyKey, in: contents)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// Clamps a sidebar font size to its allowed range, substituting the default
    /// for non-finite input.
    public func clampedSidebarFontSize(_ value: Double) -> Double {
        guard value.isFinite else { return Self.defaultSidebarFontSize }
        return min(max(value, Self.minSidebarFontSize), Self.maxSidebarFontSize)
    }

    /// The clamped sidebar font size formatted for display.
    public func formattedSidebarFontSize(_ value: Double) -> String {
        formattedFontSize(clampedSidebarFontSize(value))
    }

    /// The clamped sidebar font size parsed from a Ghostty config body, or `nil`
    /// when absent.
    public func parsedSidebarFontSize(in contents: String) -> Double? {
        parsedFontSize(in: contents, key: Self.sidebarFontSizeKey, clamp: clampedSidebarFontSize)
    }

    /// Clamps a surface-tab-bar font size to its allowed range, substituting the
    /// default for non-finite input.
    public func clampedSurfaceTabBarFontSize(_ value: Double) -> Double {
        guard value.isFinite else { return Self.defaultSurfaceTabBarFontSize }
        return min(max(value, Self.minSurfaceTabBarFontSize), Self.maxSurfaceTabBarFontSize)
    }

    /// The clamped surface-tab-bar font size formatted for display.
    public func formattedSurfaceTabBarFontSize(_ value: Double) -> String {
        formattedFontSize(clampedSurfaceTabBarFontSize(value))
    }

    /// The clamped surface-tab-bar font size parsed from a Ghostty config body,
    /// or `nil` when absent.
    public func parsedSurfaceTabBarFontSize(in contents: String) -> Double? {
        parsedFontSize(in: contents, key: Self.surfaceTabBarFontSizeKey, clamp: clampedSurfaceTabBarFontSize)
    }

    /// Formats a point size for display, trimming trailing zeros (`12`, `13.5`, `13.75`).
    public func formattedFontSize(_ value: Double) -> String {
        let scaled = Int((value * 100).rounded())
        let whole = scaled / 100
        let fraction = abs(scaled % 100)
        if fraction == 0 {
            return "\(whole)"
        }
        if fraction % 10 == 0 {
            return "\(whole).\(fraction / 10)"
        }
        return "\(whole).\(fraction < 10 ? "0" : "")\(fraction)"
    }

    /// Reads the last occurrence of `key` from a Ghostty config body and clamps it to the setting's range.
    private func parsedFontSize(
        in contents: String,
        key: String,
        clamp: (Double) -> Double
    ) -> Double? {
        guard let rawValue = parsedValue(for: key, in: contents) else {
            return nil
        }
        let unquoted = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard let value = Double(unquoted), value.isFinite else {
            return nil
        }
        return clamp(value)
    }

    /// The last value assigned to `key` in a Ghostty config body, or `nil`.
    public func parsedValue(for key: String, in contents: String) -> String? {
        var latestValue: String?
        for line in contents.components(separatedBy: .newlines) {
            guard let setting = parsedSetting(in: line), setting.key == key else {
                continue
            }
            latestValue = setting.value
        }
        return latestValue
    }

    /// Returns `contents` with every assignment to `key` replaced by `value`,
    /// appending a new assignment when the key is absent.
    public func updatedContents(_ contents: String, setting key: String, value: String) -> String {
        var lines = contents.components(separatedBy: "\n")
        if contents.hasSuffix("\n") {
            lines.removeLast()
        }
        if lines.count == 1, lines[0].isEmpty {
            lines = []
        }

        var didReplace = false
        for index in lines.indices {
            guard parsedSetting(in: lines[index])?.key == key else {
                continue
            }
            lines[index] = "\(key) = \(value)"
            didReplace = true
        }

        if !didReplace {
            lines.append("\(key) = \(value)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes `value` for `key` to the config at `url`, following symlinks and
    /// creating intermediate directories as needed.
    public func writeSetting(
        key: String,
        value: String,
        to url: URL,
        fileManager: FileManager = .default
    ) throws {
        let writeURL = configWriteURL(for: url, fileManager: fileManager)
        let contents = (try? String(contentsOf: writeURL, encoding: .utf8))
            ?? (try? String(contentsOf: url, encoding: .utf8))
            ?? ""
        let updated = updatedContents(contents, setting: key, value: value)
        try fileManager.createDirectory(
            at: writeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try updated.write(to: writeURL, atomically: true, encoding: .utf8)
    }

    private func parsedSetting(in line: String) -> (key: String, value: String)? {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        // Strip a leading UTF-8 BOM so a BOM-encoded first line still matches its
        // key (otherwise the setting reads as absent and a duplicate is appended).
        if trimmed.hasPrefix("\u{FEFF}") {
            trimmed.removeFirst()
            trimmed = trimmed.trimmingCharacters(in: .whitespaces)
        }
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: "=") else {
            return nil
        }
        let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
        let valueStart = trimmed.index(after: separator)
        let value = trimmed[valueStart...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    private func configWriteURL(for url: URL, fileManager: FileManager) -> URL {
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
            return url
        }
        let destinationURL: URL
        if destination.hasPrefix("/") {
            destinationURL = URL(fileURLWithPath: destination)
        } else {
            destinationURL = url.deletingLastPathComponent().appendingPathComponent(destination)
        }
        return destinationURL.standardizedFileURL.resolvingSymlinksInPath()
    }
}
