import SwiftUI

/// Where the settings detail scroll view lands for one navigation request.
///
/// The detail shows one pane at a time inside a single `ScrollView`, so a
/// pane can arrive while the scroll view still holds the previous pane's
/// offset. Opening a section therefore scrolls to ``topAnchorID``, a
/// zero-height marker above the content's top padding, which is the pane's
/// natural resting position. Anchors inside a pane keep their own targets:
/// a subsection (Browser Import) pins its header to the top and a setting
/// row is centered.
struct SettingsDetailScrollPlacement: Equatable {
    /// The marker at the very top of the detail scroll content.
    static let topAnchorID = "settings.detail.top"

    let anchorID: String
    let anchor: UnitPoint

    /// - Parameters:
    ///   - target: The canonical section the request navigates to.
    ///   - anchorID: The canonical anchor the request asked for.
    static func resolve(target: SettingsSectionID, anchorID: String) -> Self {
        let pane = SettingsSectionMountModel.hostSection(for: target)
        if anchorID == "section:\(pane.rawValue)" {
            return Self(anchorID: topAnchorID, anchor: .top)
        }
        if anchorID == "section:\(target.canonicalSection.rawValue)" {
            return Self(anchorID: anchorID, anchor: .top)
        }
        return Self(anchorID: anchorID, anchor: .center)
    }

    /// The navigation a window posts when it appears: a targeted open's
    /// section, otherwise the last-viewed section. Always the section
    /// itself, never a setting row a search hit left selected, so reopening
    /// Settings lands at the top of the pane instead of mid-pane.
    static func restoreTarget(
        initialSection: SettingsSectionID?,
        lastViewedSection: SettingsSectionID
    ) -> (section: SettingsSectionID, anchorID: String) {
        let section = initialSection ?? lastViewedSection
        return (section, "section:\(section.canonicalSection.rawValue)")
    }
}
