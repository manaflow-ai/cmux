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
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "palette.settings")

    init(settings: SettingsController) {
        self.settings = settings
    }

    var rows: [PaletteSettingRow] {
        let root = settings.snapshot.root
        let colors = Self.themeColors()
        return SettingsSchema.all.filter(\.isPaletteExposed).map { descriptor in
            row(descriptor, current: descriptor.effectiveValue(in: root), colors: colors)
        }
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
        write(descriptor, value)
    }

    func commit(row: String, text: String) {
        guard let descriptor = descriptor(row), let value = Self.parse(text, for: descriptor) else { return }
        write(descriptor, value)
    }

    private func write(_ descriptor: SettingDescriptor, _ value: JSONValue?) {
        let settings = settings
        Task {
            do {
                try await settings.commitPreview(descriptor, value)
            } catch {
                Self.logger.error("palette setting \(descriptor.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func descriptor(_ id: String) -> SettingDescriptor? {
        SettingsSchema.descriptor(for: id.split(separator: ".").map(String.init))
    }

    private func row(_ descriptor: SettingDescriptor, current: JSONValue?, colors: [ThemeRGB]) -> PaletteSettingRow {
        let options = descriptor.paletteOptions(current: current, themeColors: colors)
        let currentOption = options.first(where: \.isCurrent)
        let label = currentOption?.title ?? current?.compactText ?? descriptor.defaultLabel ?? ""
        let kind: PaletteSettingRow.Kind
        if descriptor.kind == .toggle {
            kind = .toggle(isOn: current?.boolValue ?? false)
        } else {
            let custom = Self.customInput(for: descriptor)
            kind = .options(options.map { PaletteSettingOption(id: $0.id, title: $0.title, swatches: $0.swatches, isCurrent: $0.isCurrent) },
                            customInput: custom)
        }
        return PaletteSettingRow(
            id: descriptor.id, title: descriptor.title, group: descriptor.group, value: label, kind: kind,
            keywords: descriptor.keywords + [descriptor.id, descriptor.section.title, descriptor.group],
            swatches: currentOption?.swatches ?? [], isEnabled: settings.managedKeys[descriptor.id] == nil
        )
    }

    /// Typed text for kinds whose value is not in a list: a number off the
    /// steps, a hex color, a font, a sound, an address.
    private static func customInput(for descriptor: SettingDescriptor) -> PaletteSettingCustomInput? {
        switch descriptor.kind {
        case .toggle, .choice: nil
        case .hostList, .timeRange: nil
        case .color:
            PaletteSettingCustomInput(placeholder: "#RRGGBB") { parse($0, for: descriptor) != nil }
        case .number(let number), .choiceOrNumber(_, let number):
            PaletteSettingCustomInput(placeholder: "\(number.range.lowerBound.formatted())–\(number.range.upperBound.formatted())") {
                parse($0, for: descriptor) != nil
            }
        case .sound, .url, .theme, .fontFamily:
            PaletteSettingCustomInput(placeholder: descriptor.title) { parse($0, for: descriptor) != nil }
        }
    }

    /// The JSON value for typed text, when the schema accepts it.
    static func parse(_ text: String, for descriptor: SettingDescriptor) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let candidate: JSONValue = switch descriptor.kind {
        case .number, .choiceOrNumber: Double(trimmed).map(JSONValue.number) ?? .string(trimmed)
        default: .string(trimmed)
        }
        return descriptor.accepts(candidate) ? candidate : nil
    }

    /// The value behind an option id (`SettingOption.id`): "reset" is nil.
    static func value(_ option: String) -> JSONValue? {
        guard option != "reset" else { return nil }
        return (try? JSONValue.parse(Data(option.utf8))) ?? .string(option)
    }

    /// The current theme's colors for a color setting's swatches: the
    /// foreground, the background, then ANSI 0 to 15.
    static func themeColors() -> [ThemeRGB] {
        let tokens = ThemeStore.shared.tokens
        return [tokens.textPrimary, tokens.windowBackground] + tokens.ansi
    }
}
