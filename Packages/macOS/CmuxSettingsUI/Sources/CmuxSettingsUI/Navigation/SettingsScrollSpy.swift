import SwiftUI

/// Scroll-spy plumbing for the settings detail pane: each section reports its
/// top offset within the detail `ScrollView`, and the sidebar highlight follows
/// whichever section currently sits at the top of the viewport. This is the
/// reverse of the existing click→scroll flow (which stays as-is).
enum SettingsScrollSpy {
    /// Named coordinate space of the detail `ScrollView`; section offsets are
    /// reported relative to it.
    static let coordinateSpace = "settingsDetailScroll"

    /// A section becomes "current" once its top scrolls to within this many
    /// points of the viewport top. Sits below the detail's top padding so the
    /// first section is selected at rest.
    static let activationLine: CGFloat = 96

    /// Picks the active section from the reported top offsets.
    ///
    /// Offsets are each section top's `minY` in the scroll coordinate space:
    /// ~0 when a section is pinned to the top, negative once scrolled above it.
    /// The active section is the one whose top is nearest the activation line
    /// from above (i.e. already scrolled past it). When nothing has reached the
    /// line yet (viewport sitting above the first section), the topmost section
    /// wins so the first row stays selected at rest.
    static func activeSection(
        offsets: [SettingsSectionID: CGFloat],
        activationLine: CGFloat = SettingsScrollSpy.activationLine
    ) -> SettingsSectionID? {
        guard !offsets.isEmpty else { return nil }
        let reached = offsets.filter { $0.value <= activationLine }
        if let best = reached.max(by: { $0.value < $1.value }) {
            return best.key
        }
        return offsets.min(by: { $0.value < $1.value })?.key
    }
}

/// Collects each section's top offset (keyed by section) up the view tree.
struct SettingsSectionOffsetKey: PreferenceKey {
    static var defaultValue: [SettingsSectionID: CGFloat] { [:] }
    static func reduce(
        value: inout [SettingsSectionID: CGFloat],
        nextValue: () -> [SettingsSectionID: CGFloat]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Tags a settings section with its scroll anchor id (matching
    /// `SettingsWindowRoot.anchorID(for:)`) and reports its top offset in the
    /// detail scroll's coordinate space so scroll-spy can track it. Replaces the
    /// bare `.id(anchorID(for:))` the sections used before.
    func settingsSectionAnchor(_ section: SettingsSectionID) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SettingsSectionOffsetKey.self,
                    value: [section: proxy.frame(in: .named(SettingsScrollSpy.coordinateSpace)).minY]
                )
            }
        )
        .id("section:\(section.rawValue)")
    }
}
