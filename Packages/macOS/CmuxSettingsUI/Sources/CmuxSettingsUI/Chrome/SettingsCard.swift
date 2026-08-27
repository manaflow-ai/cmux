import AppKit
import SwiftUI

/// Rounded grouped container for a vertical stack of
/// ``SettingsCardRow``s separated by ``SettingsCardDivider``s.
///
/// Mirrors the legacy in-app chrome: a 13pt-corner-radius rectangle
/// filled with translucent control background and a half-opacity
/// separator stroke. Hosts use one ``SettingsCard`` per subsection
/// of the settings page.
///
/// ```swift
/// SettingsSectionHeader("Appearance")
/// SettingsCard {
///     SettingsCardRow(...)
///     SettingsCardDivider()
///     SettingsCardRow(...)
/// }
/// ```
@MainActor
public struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(nsColor: NSColor.controlBackgroundColor).opacity(0.76))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Color(nsColor: NSColor.separatorColor).opacity(0.5), lineWidth: 1)
                )
        )
    }
}
