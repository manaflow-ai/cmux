import Foundation

struct WindowTitleTemplate: Equatable, Sendable {
    static let userDefaultsKey = "windowTitleTemplate"
    static let defaultRawValue = ""

    var rawValue: String

    static func configured(defaults: UserDefaults = .standard) -> WindowTitleTemplate? {
        let rawValue = defaults.string(forKey: userDefaultsKey) ?? defaultRawValue
        guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return WindowTitleTemplate(rawValue: rawValue)
    }

    func resolved(context: WindowTitleTemplateContext) -> String {
        let replacements = Dictionary(uniqueKeysWithValues: replacements(context: context))
        var resolved = ""
        var index = rawValue.startIndex
        while index < rawValue.endIndex {
            guard rawValue[index] == "{",
                  let closeIndex = rawValue[index...].firstIndex(of: "}") else {
                resolved.append(rawValue[index])
                index = rawValue.index(after: index)
                continue
            }

            let placeholderStart = rawValue.index(after: index)
            let placeholder = String(rawValue[placeholderStart..<closeIndex])
            if let replacement = replacements[placeholder] {
                resolved += replacement
            } else {
                resolved += String(rawValue[index...closeIndex])
            }
            index = rawValue.index(after: closeIndex)
        }
        return resolved
    }

    private func replacements(context: WindowTitleTemplateContext) -> [(String, String)] {
        [
            ("windowId", context.windowId.uuidString.lowercased()),
            ("windowToken", Self.windowToken(for: context.windowId)),
            ("activeWorkspace", context.activeWorkspace),
            ("activePanel", context.focusedPanel),
            ("focusedPanel", context.focusedPanel),
            ("activeDirectory", context.activeDirectory),
            ("defaultTitle", context.defaultTitle),
            ("appName", context.appName),
        ]
    }

    private static func windowToken(for windowId: UUID) -> String {
        String(windowId.uuidString.prefix(8)).lowercased()
    }
}
