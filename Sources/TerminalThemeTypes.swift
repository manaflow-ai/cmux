import Foundation

enum TerminalThemeMode: Equatable, Hashable {
    case custom
    case named(String)
    case adaptive(light: String, dark: String)

    var rawThemeValue: String? {
        switch self {
        case .custom:
            return nil
        case .named(let name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .adaptive(let light, let dark):
            return TerminalThemeSettings.encodedThemeValue(light: light, dark: dark)
        }
    }
}

struct TerminalThemeSelection: Equatable {
    let mode: TerminalThemeMode
    let rawValue: String?
    let light: String?
    let dark: String?
    let sourcePath: String?

    static let custom = TerminalThemeSelection(
        mode: .custom,
        rawValue: nil,
        light: nil,
        dark: nil,
        sourcePath: nil
    )
}
