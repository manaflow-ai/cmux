import AppKit
import CmuxNextDesign
import CmuxNextSettings
import SwiftUI

/// `terminal.fontFamily`: the Ghostty config's font, or a fixed-pitch
/// family installed on this Mac. A family the file names that is not
/// installed stays listed, so the pop-up never hides what applies.
struct FontFamilyControl: View {
    let model: SettingsWindowModel
    let descriptor: SettingDescriptor
    /// Installed fixed-pitch families, sorted; listed once per launch.
    static let installedFamilies: [String] = {
        let manager = NSFontManager.shared
        let names = manager.availableFontNames(with: .fixedPitchFontMask) ?? []
        let families = Set(names.compactMap { NSFont(name: $0, size: 0)?.familyName })
            .filter { TerminalFontSetting.isValidFamily($0) && !$0.hasPrefix(".") }
        return families.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }()

    var body: some View {
        let current = model.value(descriptor)?.stringValue ?? ""
        let families = Self.installedFamilies
        Picker("", selection: Binding<String>(
            get: { current },
            set: { model.set(descriptor, $0.isEmpty ? nil : .string($0)) })) {
            Text(descriptor.defaultLabel ?? "").tag("")
            Divider()
            ForEach(families.contains(current) || current.isEmpty ? families : [current] + families, id: \.self) {
                Text($0).tag($0)
            }
        }
        .labelsHidden().pickerStyle(.menu).fixedSize()
        .accessibilityIdentifier("cmux.settings.control.\(descriptor.id)")
    }
}
