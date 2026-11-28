import CmuxNextActions
package import CmuxNextDesign
package import CmuxNextPalette
package import CmuxNextSettings
package import Foundation
import os

/// Every palette-exposed schema setting as a palette row (R93): the one
/// generic mechanism, so a new schema row appears in the palette with no
/// other edit. A toggle flips; a choice, number or color lists its values
/// (colors as swatches, R98) with live preview through
/// `SettingsController.preview`; free-text kinds take typed text. Every
/// write goes through `SettingsController.setSetting` (the managed guard
/// and the schema check).
@MainActor
package final class SettingsPaletteSource: PaletteSettingsSource {
    private let settings: SettingsController
    /// The theme colors of the window the palette serves (its theme scope).
    private let themeColors: @MainActor () -> [ThemeRGB]
    /// Every Ghostty theme and its swatch strip, for theme settings (R98).
    private let themes: (any SettingsPaletteThemes)?
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "palette.settings")
    /// Values committed whose write has not landed, by setting id: the rows show them at once
    /// (nil: the default). Each write's token, so only the latest write of a row clears it.
    private var pending: [String: (token: Int, value: JSONValue?)] = [:] { didSet { pendingRevision += 1 } }
    private var pendingRevision = 0
    private var writeCount = 0
    /// The palette's page reload (`observeChanges`).
    private var onChange: (@MainActor () -> Void)?
    /// Opens the Settings page at a row (the `openSettings setting:` action); nil offers no Show in Settings.
    private let openSetting: (@MainActor (String) -> Void)?

    package init(settings: SettingsController, themes: (any SettingsPaletteThemes)? = nil, openSetting: (@MainActor (String) -> Void)? = nil,
         themeColors: @escaping @MainActor () -> [ThemeRGB]) {
        self.settings = settings
        self.themes = themes
        self.themeColors = themeColors
        self.openSetting = openSetting
    }

    package var revealsInSettings: Bool { openSetting != nil }

    package func reveal(row: String) {
        openSetting?(row)
    }

    /// What the rows are built from. The loaded settings, managed keys and theme files change only in a
    /// load that applied something (`appliedCount`); the rest changes here or in the theme catalog.
    private struct RowsInputs: Equatable {
        let loads: Int
        let pending: Int
        let colors: [ThemeRGB]
        let themes: Int?
        let recentFonts: [String]
        let developerTools: Bool
        /// Numbers and durations are formatted for it.
        let locale: String
    }

    /// The rows last built and their inputs: an open with the same inputs lists them again.
    private var built: (inputs: RowsInputs, rows: [PaletteSettingRow])?
    /// Times the rows were built (the reuse tests).
    package private(set) var rowBuilds = 0

    /// Every palette setting's row with its whole value list (formatted numbers and durations, the
    /// theme and font lists): about 8 ms of the main thread, read after each Cmd-Shift-P's first
    /// frame. Built again only when an input changed, not on every open.
    package var rows: [PaletteSettingRow] {
        let colors = themeColors()
        let developerTools = DevTools.isEnabled
        let inputs = RowsInputs(loads: settings.appliedCount, pending: pendingRevision, colors: colors, themes: themes?.revision,
                                recentFonts: settings.recentFonts.families, developerTools: developerTools,
                                locale: Locale.autoupdatingCurrent.identifier)
        if let built, built.inputs == inputs { return built.rows }
        let root = settings.snapshot.root
        let rows = SettingsSchema.all.filter { $0.isPaletteListed(developerTools: developerTools) }.map { descriptor in
            let current = pending[descriptor.id].map { $0.value ?? settings.defaultValue(of: descriptor) } ?? descriptor.effectiveValue(in: root)
            return row(descriptor, current: current, inherited: descriptor.inheritedValue(in: root), colors: colors)
        }
        built = (inputs, rows)
        rowBuilds += 1
        return rows
    }

    package var navigationItems: [PaletteItem] {
        let key = "card.cloudModels"
        let title = SettingsDeepLink.cloudModelsTitle
        var item = PaletteItem(
            id: key, title: title, symbol: "cloud", section: SettingsPaletteProvider.section,
            keywords: ["settings", "cloud models", "Claude", "ChatGPT", "API key", "endpoint"],
            primary: PaletteCommand(id: "open", title: title, symbol: "return",
                                    effect: .perform { [openSetting] in openSetting?(key) })
        )
        item.hidesWhenQueryEmpty = true
        return [item]
    }

    package func observeChanges(_ onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    package func preview(row: String, option: String?) {
        guard let descriptor = descriptor(row) else { return }
        guard let option else {
            settings.endPreview()
            return
        }
        settings.preview(descriptor, SettingOption.value(option))
    }

    package func commit(row: String, option: String) {
        guard let descriptor = descriptor(row) else { return }
        let value: JSONValue? = switch option {
        case "on": .bool(true)
        case "off": .bool(false)
        default: SettingOption.value(option)
        }
        commitValue(descriptor, value)
    }

    package func commit(row: String, text: String) {
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

    private func row(_ descriptor: SettingDescriptor, current: JSONValue?, inherited: JSONValue?, colors: [ThemeRGB]) -> PaletteSettingRow {
        let isFont = descriptor.kind == .fontFamily
        let options = if descriptor.kind == .theme, let themes {
            SettingOption.themeOptions(current: current?.stringValue, names: themes.names, defaultLabel: descriptor.defaultLabel ?? "",
                              strip: themes.swatches(for:))
        } else if isFont {
            settings.recentFonts.options(current: current?.stringValue, families: AppFontSetting.families(for: descriptor.id, fixedPitch: TerminalFontSetting.installedFamilies), defaultLabel: descriptor.defaultLabel ?? descriptor.title)
        } else {
            settings.paletteOptions(descriptor, current: current, inherited: inherited, themeColors: colors)
        }
        let currentOption = options.first(where: \.isCurrent)
        let label = descriptor.paletteSummary(current: current, options: options) ?? currentOption?.title ?? current?.compactText ?? descriptor.defaultLabel ?? ""
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
        case .hostList, .folderList, .timeRange, .numberList, .stringMap, .soundRules, .stringList, .orderedChoices, .choiceSet, .json: nil
        case .color:
            PaletteSettingCustomInput(placeholder: "#RRGGBB") { descriptor.value(typed: $0) != nil }
        case .number(let number), .choiceOrNumber(_, let number):
            PaletteSettingCustomInput(placeholder: "\(number.range.lowerBound.formatted()) - \(number.range.upperBound.formatted())") {
                descriptor.value(typed: $0) != nil
            }
        case .choiceOrURL:
            PaletteSettingCustomInput(placeholder: "http://mini.tail1234.ts.net:7320") { descriptor.value(typed: $0) != nil }
        case .sound, .url, .theme, .fontFamily, .text:
            PaletteSettingCustomInput(placeholder: descriptor.title) { descriptor.value(typed: $0) != nil }
        }
    }

    /// A color setting's swatches from `tokens`: the foreground, the
    /// background, then ANSI 0 to 15.
    package static func themeColors(_ tokens: ThemeTokens) -> [ThemeRGB] {
        [tokens.textPrimary, tokens.windowBackground] + tokens.ansi
    }
}

/// Theme names and swatches supplied by the app's theme catalog.
@MainActor
package protocol SettingsPaletteThemes: AnyObject {
    var names: [String] { get }
    var revision: Int { get }
    func swatches(for name: String) -> [ThemeRGB]
}
