public import CmuxNextDesign

/// `appearance.fonts.*` in cmux.json (`AppFonts`): `ui` is the text face of chrome and pages
/// ("system", "rounded", "serif", "mono"), `code` the family code draws in (absent: the
/// terminal's), `chatSize` the chat's text size in points (11 to 20; absent: 14). A missing key is
/// today's look; a bad value is that plus a diagnostic.
public nonisolated struct AppFontsSetting: Sendable {
    public static let uiPath = ["appearance", "fonts", "ui"]
    public static let codePath = ["appearance", "fonts", "code"]
    public static let chatSizePath = ["appearance", "fonts", "chatSize"]

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> AppFonts {
        var fonts = AppFonts()
        if let value = root.value(at: uiPath) {
            if let text = value.stringValue, let design = AppFonts.Design(rawValue: text) {
                fonts.design = design
            } else {
                let choices = AppFonts.Design.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: uiPath.joined(separator: "."), message: "expected one of \(choices)"))
            }
        }
        if let value = root.value(at: codePath), value != .null {
            let family = value.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
            if TerminalFontSetting().isValidFamily(family) {
                fonts.code = family
            } else if !(value.stringValue.map { $0.trimmingCharacters(in: .whitespaces).isEmpty } ?? false) {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: codePath.joined(separator: "."),
                                                      message: "expected a font family name of at most \(TerminalFontSetting().maximumFamilyLength) characters, without # = or \""))
            }
        }
        if let value = root.value(at: chatSizePath) {
            if let size = value.doubleValue, size.isFinite, AppFonts.chatSizeRange.contains(size) {
                fonts.chatSize = size
            } else {
                let range = AppFonts.chatSizeRange
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: chatSizePath.joined(separator: "."),
                                                      message: "expected a size in points from \(Int(range.lowerBound)) to \(Int(range.upperBound))"))
            }
        }
        return fonts
    }

    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.fonts", "Fonts")
        return [
            SettingDescriptor(
                uiPath, section: .appearance, group: group,
                title: SettingsText.keyed("settings.fonts.ui", "Text Font"),
                help: SettingsText.keyed("settings.fonts.ui.help", "The face of chats, the composer, pages and the window's own text."),
                kind: .choice(AppFonts.Design.allCases.map { design in
                    switch design {
                    case .system: SettingChoice(design.rawValue, SettingsText.keyed("settings.choice.fontSystem", "System"))
                    case .rounded: SettingChoice(design.rawValue, SettingsText.keyed("settings.choice.fontRounded", "Rounded"))
                    case .serif: SettingChoice(design.rawValue, SettingsText.keyed("settings.choice.fontSerif", "Serif"))
                    case .mono: SettingChoice(design.rawValue, SettingsText.keyed("settings.choice.fontMono", "Monospaced"))
                    }
                }),
                default: .string(AppFonts.Design.system.rawValue),
                keywords: ["font", "typeface", "text", "chat", "serif", "rounded", "monospace", "ui"]
            ),
            SettingDescriptor(
                codePath, section: .appearance, group: group,
                title: SettingsText.keyed("settings.fonts.code", "Code Font"),
                help: SettingsText.keyed("settings.fonts.code.help", "The face of code in chats, diffs and files. Unset, code uses the terminal's font."),
                kind: .fontFamily, default: nil, defaultLabel: SettingsText.keyed("settings.fonts.code.default", "Terminal Font"),
                keywords: ["font", "code", "monospace", "monospaced", "typeface", "diff", "editor"]
            ),
            SettingDescriptor(
                chatSizePath, section: .appearance, group: group,
                title: SettingsText.keyed("settings.fonts.chatSize", "Chat Text Size"),
                help: SettingsText.keyed("settings.fonts.chatSize.help", "The size of chat messages."),
                kind: .number(SettingNumber(AppFonts.chatSizeRange, step: 1, unit: .points, placeholder: AppFonts.defaultChatSize)),
                default: .number(AppFonts.defaultChatSize),
                keywords: ["font", "text", "size", "chat", "composer", "bigger", "smaller"]
            ),
        ]
    }
}

extension SettingsApplier {
    /// Copies `appearance.fonts.*` into `design`; on a change, every page gets its theme again
    /// (the faces ride on `WebTheme`'s variables) and the chrome redraws.
    static func applyFonts(_ snapshot: CmuxConfigSnapshot, to design: DesignSettings) {
        var ignored: [SettingsDiagnostic] = [] // the parse reported them (`ChromePlacementSetting.parse`)
        let fonts = AppFontsSetting.parse(snapshot.root, diagnostics: &ignored)
        guard design.fonts != fonts else { return }
        design.fonts = fonts
        ThemeStore.shared.repaintAll()
    }
}
