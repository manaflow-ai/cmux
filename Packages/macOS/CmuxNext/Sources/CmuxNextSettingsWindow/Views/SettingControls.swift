import AppKit
import CmuxNextDesign
import CmuxNextSettings
import SwiftUI

/// A color well; unset shows the default's name (the theme color).
struct ColorControl: View {
    let model: SettingsWindowModel
    let descriptor: SettingDescriptor

    var body: some View {
        let hex = model.value(descriptor)?.stringValue
        HStack(spacing: Metrics.space3) {
            if hex == nil, let label = descriptor.defaultLabel {
                Text(label).foregroundStyle(SettingsStyle.secondary)
            }
            ColorPicker("", selection: Binding<Color>(
                get: { hex.flatMap { ThemeRGB(cssHex: $0) }.map { Color(nsColor: $0.nsColor) } ?? SettingsStyle.secondary },
                set: { model.set(descriptor, .string(ColorHex.string(NSColor($0)))) }), supportsOpacity: true)
                .labelsHidden()
        }
    }
}

enum ColorHex {
    /// `#RRGGBB`, or `#RRGGBBAA` when not opaque.
    static func string(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let parts = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int(($0 * 255).rounded()) }
        let alpha = Int((rgb.alphaComponent * 255).rounded())
        let base = parts.map { String(format: "%02X", min(max($0, 0), 255)) }.joined()
        return "#" + base + (alpha < 255 ? String(format: "%02X", max(alpha, 0)) : "")
    }
}

/// Default, None, or a sound from /System/Library/Sounds.
struct SoundControl: View {
    let model: SettingsWindowModel
    let descriptor: SettingDescriptor
    static let systemSounds: [String] = {
        let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/System/Library/Sounds"),
                                                                  includingPropertiesForKeys: nil)) ?? []
        return urls.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }()

    var body: some View {
        let current = model.value(descriptor)?.stringValue ?? "default"
        Picker("", selection: Binding<String>(get: { current }, set: { name in
            model.set(descriptor, .string(name))
            if name != "default", name != "none" { NSSound(named: NSSound.Name(name))?.play() }
        })) {
            Text(SettingsWindowStrings.soundDefault).tag("default")
            Text(SettingsWindowStrings.soundNone).tag("none")
            Divider()
            ForEach(Self.systemSounds + (Self.systemSounds.contains(current) || ["default", "none"].contains(current) ? [] : [current]),
                    id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden().pickerStyle(.menu).fixedSize()
    }
}
