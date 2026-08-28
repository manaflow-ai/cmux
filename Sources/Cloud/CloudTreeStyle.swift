import Foundation
import SwiftUI

/// One visual preset for the Cloud tree. The presets are deliberately
/// different *shapes*, not one look at five font sizes: each picks a leaf
/// layout, an icon treatment, a group-label voice, and a metadata placement.
/// Rows, the cell, and the outline read the active style; the debug gallery
/// (Debug → Debug Windows → Cloud Tree Style Gallery…) renders every preset
/// side by side so a variant is picked by looking, not by rebuilding.
struct CloudTreeStyle: Equatable, Identifiable, Sendable {
    enum MachineRowLayout: String, Sendable {
        /// Name line plus a dim subtitle (and stats when enabled).
        case twoLine
        /// One Finder-like line: dot, name, dim inline detail.
        case singleLine
    }

    enum LeafLayout: String, Sendable {
        /// Title and dim detail on one baseline.
        case singleLine
        /// Title over its dim detail, like a rich list cell.
        case twoLine
    }

    enum IconTreatment: String, Sendable {
        /// Secondary/tertiary label-colored glyphs (the Files-tree look).
        case monochrome
        /// Semantic-colored glyphs (folder blue, display teal).
        case tinted
        /// System Settings-style filled squircle chips with white glyphs.
        case chips
    }

    enum GroupLabelStyle: String, Sendable {
        case plain
        /// UPPERCASE tracked mini-caps, like Finder sidebar sections.
        case uppercased
    }

    enum MetaPlacement: String, Sendable {
        /// Dim detail right after the title.
        case inline
        /// Dim detail right-aligned into a trailing column (table feel).
        case trailing
    }

    let id: String
    /// Gallery label. English-only: the picker is a DEBUG window.
    let name: String
    let rowHeight: CGFloat
    let machineRowLayout: MachineRowLayout
    let leafLayout: LeafLayout
    let iconTreatment: IconTreatment
    let groupLabelStyle: GroupLabelStyle
    let metaPlacement: MetaPlacement
    /// Machine rows draw a full-width tinted band behind the name.
    let machineBand: Bool
    /// Every text run uses the monospaced design (the TUI/table voice).
    let monospacedText: Bool
    /// A hairline under each non-machine row.
    let rowSeparators: Bool
    /// How far each outline depth level shifts its children. The disclosure
    /// chevron (~10pt) still fits down to ~10; smaller indents are the single
    /// biggest horizontal-space win in a 3-level tree.
    let indentPerLevel: CGFloat
    let machineNameSize: CGFloat
    let titleSize: CGFloat
    let detailSize: CGFloat
    let groupLabelSize: CGFloat
    let iconSize: CGFloat
    /// Width reserved for the leaf glyph column; 0 hides icons entirely.
    let iconSlot: CGFloat
    let iconGap: CGFloat
    /// Dim size number after pool labels ("Terminals 3").
    let showsGroupCounts: Bool
    /// The daemon-tab count badge on pool terminal rows.
    let showsViewBadges: Bool
    /// The CPU/Mem/Disk line under a machine (two-line layout only).
    let showsMachineStats: Bool
    let machineVerticalPadding: CGFloat

    var fontDesign: Font.Design { monospacedText ? .monospaced : .default }
    var machineNameLineHeight: CGFloat { machineNameSize + 3.5 }
    var machineSubtitleLineHeight: CGFloat { detailSize + 3.5 }

    func machineRowHeight(hasStats: Bool) -> CGFloat {
        switch machineRowLayout {
        case .singleLine:
            return rowHeight + (machineBand ? 7 : 2)
        case .twoLine:
            let lines = machineNameLineHeight + CloudTreeRowGrid.machineLineSpacing + machineSubtitleLineHeight
                + (hasStats && showsMachineStats ? CloudTreeRowGrid.machineLineSpacing + CloudTreeRowGrid.machineStatsLineHeight : 0)
            return machineVerticalPadding * 2 + lines
        }
    }

    // MARK: Presets

    /// The default: quiet Finder-like single lines, monochrome glyphs, tight.
    static let compact = CloudTreeStyle(
        id: "compact", name: "Compact",
        rowHeight: 20, machineRowLayout: .singleLine, leafLayout: .singleLine,
        iconTreatment: .monochrome, groupLabelStyle: .plain, metaPlacement: .inline,
        machineBand: false, monospacedText: false, rowSeparators: false,
        indentPerLevel: 11,
        machineNameSize: 12, titleSize: 11.5, detailSize: 10, groupLabelSize: 10.5,
        iconSize: 9.5, iconSlot: 14, iconGap: 6,
        showsGroupCounts: true, showsViewBadges: true, showsMachineStats: false,
        machineVerticalPadding: 3
    )

    /// System Settings voice: filled color squircles with white glyphs, so
    /// each kind reads by color before you read a word.
    static let chips = CloudTreeStyle(
        id: "chips", name: "Chips",
        rowHeight: 26, machineRowLayout: .singleLine, leafLayout: .singleLine,
        iconTreatment: .chips, groupLabelStyle: .plain, metaPlacement: .inline,
        machineBand: false, monospacedText: false, rowSeparators: false,
        indentPerLevel: 13,
        machineNameSize: 12.5, titleSize: 12, detailSize: 10.5, groupLabelSize: 11,
        iconSize: 10.5, iconSlot: 22, iconGap: 7,
        showsGroupCounts: true, showsViewBadges: true, showsMachineStats: false,
        machineVerticalPadding: 3
    )

    /// Editorial sections: machines are tinted full-width bands, group labels
    /// are UPPERCASE mini-caps, leaves stay quiet under their headers.
    static let sections = CloudTreeStyle(
        id: "sections", name: "Sections",
        rowHeight: 21, machineRowLayout: .singleLine, leafLayout: .singleLine,
        iconTreatment: .tinted, groupLabelStyle: .uppercased, metaPlacement: .inline,
        machineBand: true, monospacedText: false, rowSeparators: false,
        indentPerLevel: 12,
        machineNameSize: 12, titleSize: 11.5, detailSize: 10, groupLabelSize: 9,
        iconSize: 10, iconSlot: 15, iconGap: 6,
        showsGroupCounts: true, showsViewBadges: true, showsMachineStats: false,
        machineVerticalPadding: 3
    )

    /// A table, not a tree: monospaced text, metadata right-aligned into a
    /// column, hairline row separators. The htop of sidebars.
    static let ledger = CloudTreeStyle(
        id: "ledger", name: "Ledger",
        rowHeight: 18, machineRowLayout: .singleLine, leafLayout: .singleLine,
        iconTreatment: .monochrome, groupLabelStyle: .uppercased, metaPlacement: .trailing,
        machineBand: false, monospacedText: true, rowSeparators: true,
        indentPerLevel: 9,
        machineNameSize: 11, titleSize: 10.5, detailSize: 9.5, groupLabelSize: 8.5,
        iconSize: 8.5, iconSlot: 11, iconGap: 5,
        showsGroupCounts: true, showsViewBadges: true, showsMachineStats: false,
        machineVerticalPadding: 2
    )

    /// Roomy and demo-friendly: two-line leaves (title over detail), large
    /// tinted glyphs, two-line machine cards with the stats line back.
    static let aero = CloudTreeStyle(
        id: "aero", name: "Aero",
        rowHeight: 34, machineRowLayout: .twoLine, leafLayout: .twoLine,
        iconTreatment: .tinted, groupLabelStyle: .plain, metaPlacement: .inline,
        machineBand: false, monospacedText: false, rowSeparators: false,
        indentPerLevel: 15,
        machineNameSize: 13, titleSize: 12.5, detailSize: 10.5, groupLabelSize: 11,
        iconSize: 14, iconSlot: 22, iconGap: 8,
        showsGroupCounts: true, showsViewBadges: true, showsMachineStats: true,
        machineVerticalPadding: 4
    )

    /// Gallery order. `compact` is the shipped default.
    static let presets: [CloudTreeStyle] = [.compact, .chips, .sections, .ledger, .aero]

    static let defaultStyle: CloudTreeStyle = .compact

    static func preset(id: String) -> CloudTreeStyle? {
        presets.first { $0.id == id }
    }
}

/// The one place the active style lives (a UserDefaults-backed debug tuning
/// value while the variants are dogfooded; the winner becomes the only style).
/// Nonisolated on purpose: UserDefaults is thread-safe and the value feeds
/// default arguments, which evaluate outside the main actor.
enum CloudTreeStyleStore {
    static let defaultsKey = "cloudTree.style"
    static let didChangeNotification = Notification.Name("cmux.cloudTree.styleDidChange")

    static var current: CloudTreeStyle {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let style = CloudTreeStyle.preset(id: raw) else {
                return .defaultStyle
            }
            return style
        }
        set {
            UserDefaults.standard.set(newValue.id, forKey: defaultsKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }
}
