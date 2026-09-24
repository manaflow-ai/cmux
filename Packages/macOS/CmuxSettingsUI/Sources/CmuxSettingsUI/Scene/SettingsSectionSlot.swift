import CmuxFoundation
import SwiftUI

/// One section's slot in the settings detail stack: the section content
/// once ``SettingsSectionMountModel`` has mounted it, a lightweight
/// placeholder until then (https://github.com/manaflow-ai/cmux/issues/12134).
///
/// The slot owns the section's `scrollTo` anchor (`section:<raw>`) so a
/// placeholder is addressable exactly like mounted content, and it reports
/// the mounted content's `onAppear` back to the scene, which uses that
/// "this content is in the hierarchy" signal to mount the next section in
/// a later update pass.
@MainActor
struct SettingsSectionSlot<Content: View>: View {
    let section: SettingsSectionID
    let isMounted: Bool
    /// `false` renders nothing while unmounted, for sections that hide
    /// themselves entirely (Cloud before it is available).
    let showsPlaceholder: Bool
    let onMountedAppear: @MainActor () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        // The same spacing as the enclosing detail stack, so a section's
        // header and cards sit exactly where the flat stack put them.
        VStack(alignment: .leading, spacing: 14) {
            if isMounted {
                content()
                    .onAppear { onMountedAppear() }
            } else if showsPlaceholder {
                SettingsSectionPlaceholder(section: section)
            }
        }
        .id("section:\(section.rawValue)")
    }
}

/// Stand-in for a section that has not been mounted yet: the section's
/// header plus one card row, so the page keeps its shape while sections
/// fill in.
@MainActor
struct SettingsSectionPlaceholder: View {
    let section: SettingsSectionID

    var body: some View {
        SettingsSectionHeader(section.title, section: section)
        SettingsCard {
            HStack {
                Text(String(localized: "settings.section.loading", defaultValue: "Loading…"))
                    .cmuxFont(size: 13, weight: .medium)
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .accessibilityIdentifier("SettingsSectionPlaceholder.\(section.rawValue)")
    }
}
