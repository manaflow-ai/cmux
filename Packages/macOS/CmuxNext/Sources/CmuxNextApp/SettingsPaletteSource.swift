import CmuxNextActions
import CmuxNextDesign
import CmuxNextPalette
import CmuxNextSettings
import Foundation
import os

/// Every palette-exposed schema setting as a palette row (R93): the one
/// generic mechanism, so a new schema row appears in the palette with no
/// other edit. A toggle flips; a choice, number or color lists its values
/// (colors as swatches, R98) with live preview through
/// `SettingsController.preview`; free-text kinds take typed text. Every
/// write goes through `SettingsController.setSetting` (the managed guard
/// and the schema check).
@MainActor
final class SettingsPaletteSource: PaletteSettingsSource {
    private let settings: SettingsController
    /// The theme colors of the window the palette serves (its theme scope).
    private let themeColors: @MainActor () -> [ThemeRGB]
    /// Every Ghostty theme and its swatch strip, for theme settings (R98).
    private let themes: ThemeCatalog?
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "palette.settings")
    /// Values committed whose write has not landed, by setting id: the rows show them at once
    /// (nil: the default). Each write's token, so only the latest write of a row clears it.
    private var pending: [String: (token: Int, value: JSONValue?)] = [:]
    private var writeCount = 0
    /// The palette's page reload (`observeChanges`).
    private var onChange: (@MainActor () -> Void)?

    init(settings: SettingsController, themes: ThemeCatalog? = nil, themeColors: @escaping @MainActor () -> [ThemeRGB]) {
        self.settings = settings
        self.themes = themes
        self.themeColors = themeColors
    }

    var rows: [PaletteSettingRow] {
        let root = settings.snapshot.root
        let colors = themeColors()
        return SettingsSchema.all.filter(\.isPaletteExposed).map { descriptor in
            let current = pending[descriptor.id].map { $0.value ?? settings.defaultValue(of: descriptor) } ?? descriptor.effectiveValue(in: root)
            return row(descriptor, current: current, colors: colors)
        }
    }

    func observeChanges(_ onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    func preview(row: String, option: String?) {
        guard let descriptor = descriptor(row) else { return }
        guard let option else {
            settings.endPreview()
            return
        }
        settings.preview(descriptor, Self.value(option))
    }

    func commit(row: String, option: String) {
        guard let descriptor = descriptor(row) else { return }
        let value: JSONValue? = switch option {
        case "on": .bool(true)
        case "off": .bool(false)
        default: Self.value(option)
        }
        commitValue(descriptor, value)
    }

    func commit(row: String, text: String) {
        guard let descriptor = descriptor(row), let value = descriptor.value(typed: text) else { return }
        commitValue(descriptor, value)
    }

    /// The row shows `value` at once (the palette reloads after the command); when the write
    /// lands, or fails and the row goes back to the stored value, the palette reloads again.
    private func commitValue(_ descriptor: SettingDescriptor, _ value: JSONValue?) {
        let settings = settings
        let id = descriptor.id
        writeCount += 1
        let token = writeCount
        pending[id] = (token, value)
        Task { [weak self] in
            do {
                try await settings.commitPreview(descriptor, value)
            } catch {
                Self.logger.error("palette setting \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
            guard let self, self.pending[id]?.token == token else { return }
            self.pending[id] = nil
            self.onChange?()
        }
    }

    private func descriptor(_ id: String) -> SettingDescriptor? {
        SettingsSchema.descriptor(for: id.split(separator: ".").map(String.init))
    }

    private func row(_ descriptor: SettingDescriptor, current: JSONValue?, colors: [ThemeRGB]) -> PaletteSettingRow {
        let isFont = descriptor.kind == .fontFamily
        let options = if descriptor.kind == .theme, let themes {
            Self.themeOptions(current: current?.stringValue, names: themes.names, defaultLabel: descriptor.defaultLabel ?? "",
                              strip: themes.swatches(for:))
        } else if isFont {
            settings.recentFonts.options(current: current?.stringValue, families: SettingsPageDomains.fontFamilies, defaultLabel: descriptor.defaultLabel ?? descriptor.title)
        } else {
            descriptor.paletteOptions(current: current, themeColors: colors)
        }
        let currentOption = options.first(where: \.isCurrent)
        let label = currentOption?.title ?? current?.compactText ?? descriptor.defaultLabel ?? ""
        let kind: PaletteSettingRow.Kind
        if descriptor.kind == .toggle {
            kind = .toggle(isOn: current?.boolValue ?? false)
        } else {
            let custom = Self.customInput(for: descriptor)
            kind = .options(options.map { PaletteSettingOption(id: $0.id, title: $0.title, swatches: $0.swatches, isCurrent: $0.isCurrent,
                                                               fontFamily: isFont ? $0.value?.stringValue : nil, isRecent: $0.isRecent) }, customInput: custom)
        }
        return PaletteSettingRow(
            id: descriptor.id, title: descriptor.title, group: descriptor.group, value: label, kind: kind,
            keywords: descriptor.keywords + [descriptor.id, descriptor.section.title, descriptor.group],
            swatches: currentOption?.swatches ?? [], isEnabled: settings.managedKeys[descriptor.id] == nil, isFontFamily: isFont
        )
    }

    /// Typed text for kinds whose value is not in a list: a number off the
    /// steps, a hex color, a font, a sound, an address.
    private static func customInput(for descriptor: SettingDescriptor) -> PaletteSettingCustomInput? {
        switch descriptor.kind {
        case .toggle, .choice: nil
        case .hostList, .folderList, .timeRange, .numberList, .stringMap, .soundRules, .stringList, .orderedChoices, .choiceSet: nil
        case .color:
            PaletteSettingCustomInput(placeholder: "#RRGGBB") { descriptor.value(typed: $0) != nil }
        case .number(let number), .choiceOrNumber(_, let number):
            PaletteSettingCustomInput(placeholder: "\(number.range.lowerBound.formatted())–\(number.range.upperBound.formatted())") {
                descriptor.value(typed: $0) != nil
            }
        case .choiceOrURL:
            PaletteSettingCustomInput(placeholder: "http://mini.tail1234.ts.net:7320") { descriptor.value(typed: $0) != nil }
        case .sound, .url, .theme, .fontFamily, .text:
            PaletteSettingCustomInput(placeholder: descriptor.title) { descriptor.value(typed: $0) != nil }
        }
    }

    /// The value behind an option id (`SettingOption.id`): "reset" is nil.
    static func value(_ option: String) -> JSONValue? {
        guard option != "reset" else { return nil }
        return (try? JSONValue.parse(Data(option.utf8))) ?? .string(option)
    }

    /// A theme setting's values (R98): the Ghostty config (reset) first,
    /// onboarding's themes, then every other theme in `names`, each with its
    /// swatch strip from `strip`; a current value not listed (a light/dark
    /// pair, a path) is kept after the config row.
    static func themeOptions(current: String?, names: [String], defaultLabel: String,
                             strip: (String) -> [ThemeRGB]) -> [SettingOption] {
        let curated = ActionArgument.curatedThemes.filter(names.contains)
        let listed = curated + names.filter { !curated.contains($0) }
        var options = [SettingOption(value: nil, title: defaultLabel, isCurrent: current == nil)]
        if let current, !listed.contains(current) {
            options.append(SettingOption(value: .string(current), title: current, swatches: strip(current), isCurrent: true))
        }
        options += listed.map { SettingOption(value: .string($0), title: $0, swatches: strip($0), isCurrent: current == $0) }
        return options
    }

    /// A color setting's swatches from `tokens`: the foreground, the
    /// background, then ANSI 0 to 15.
    static func themeColors(_ tokens: ThemeTokens) -> [ThemeRGB] {
        [tokens.textPrimary, tokens.windowBackground] + tokens.ansi
    }
}
