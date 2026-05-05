import Foundation

public enum TerminalThemeMode: Equatable, Hashable, Sendable {
    case custom
    case named(String)
    case adaptive(light: String, dark: String)

    public var rawThemeValue: String? {
        switch self {
        case .custom:
            return nil
        case .named(let name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return TerminalThemeSettings.isSupportedThemeName(trimmed) ? trimmed : nil
        case .adaptive(let light, let dark):
            return TerminalThemeSettings.encodedThemeValue(light: light, dark: dark)
        }
    }
}

public struct TerminalThemeSelection: Equatable, Sendable {
    public let mode: TerminalThemeMode
    public let rawValue: String?
    public let light: String?
    public let dark: String?
    public let sourcePath: String?

    public static let custom = TerminalThemeSelection(
        mode: .custom,
        rawValue: nil,
        light: nil,
        dark: nil,
        sourcePath: nil
    )
}
