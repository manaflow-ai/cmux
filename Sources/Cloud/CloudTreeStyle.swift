import Foundation
import SwiftUI

/// One visual preset for the Cloud tree. Pure metrics and switches; the rows,
/// the cell, and the outline read the active style, and the debug gallery
/// (Debug → Debug Windows → Cloud Tree Style Gallery…) renders every preset
/// side by side so a variant can be picked by looking, not by rebuilding.
struct CloudTreeStyle: Equatable, Identifiable, Sendable {
    enum MachineRowLayout: String, Sendable {
        /// Name line plus a dim subtitle (and stats when enabled).
        case twoLine
        /// One Finder-like line: dot, name, dim inline detail.
        case singleLine
    }

    enum IconTint: String, Sendable {
        /// Secondary/tertiary label colors only (the Files-tree look).
        case monochrome
        /// Finder-like: folders and machines carry their semantic color.
        case tinted
    }

    let id: String
    /// Gallery label. English-only: the picker is a DEBUG window.
    let name: String
    let rowHeight: CGFloat
    let machineRowLayout: MachineRowLayout
    let machineNameSize: CGFloat
    let titleSize: CGFloat
    let detailSize: CGFloat
    let groupLabelSize: CGFloat
    let iconSize: CGFloat
    /// Width reserved for the leaf glyph column; 0 hides icons entirely.
    let iconSlot: CGFloat
    let iconGap: CGFloat
    let iconTint: IconTint
    /// Dim size number after pool labels ("Terminals 3").
    let showsGroupCounts: Bool
    /// The daemon-tab count badge on pool terminal rows.
    let showsViewBadges: Bool
    /// The CPU/Mem/Disk line under a machine (two-line layout only).
    let showsMachineStats: Bool
    let machineVerticalPadding: CGFloat

    var machineNameLineHeight: CGFloat { machineNameSize + 3.5 }
    var machineSubtitleLineHeight: CGFloat { detailSize + 3.5 }

    func machineRowHeight(hasStats: Bool) -> CGFloat {
        switch machineRowLayout {
        case .singleLine:
            return rowHeight + 2
        case .twoLine:
            let lines = machineNameLineHeight + CloudTreeRowGrid.machineLineSpacing + machineSubtitleLineHeight
                + (hasStats && showsMachineStats ? CloudTreeRowGrid.machineLineSpacing + CloudTreeRowGrid.machineStatsLineHeight : 0)
            return machineVerticalPadding * 2 + lines
        }
    }

    // MARK: Presets

    /// The pre-iteration look: roomy two-line machine cards, monochrome glyphs.
    static let classic = CloudTreeStyle(
        id: "classic", name: "Classic",
        rowHeight: 24, machineRowLayout: .twoLine,
        machineNameSize: 12.5, titleSize: 12, detailSize: 10.5, groupLabelSize: 11,
        iconSize: 10, iconSlot: 16, iconGap: 8, iconTint: .monochrome,
        showsGroupCounts: true, showsViewBadges: true, showsMachineStats: true,
        machineVerticalPadding: 4
    )

    /// The default: one line per machine, tighter rows, everything else intact.
    static let compact = CloudTreeStyle(
        id: "compact", name: "Compact",
        rowHeight: 20, machineRowLayout: .singleLine,
        machineNameSize: 12, titleSize: 11.5, detailSize: 10, groupLabelSize: 10.5,
        iconSize: 9.5, iconSlot: 14, iconGap: 6, iconTint: .monochrome,
        showsGroupCounts: true, showsViewBadges: true, showsMachineStats: false,
        machineVerticalPadding: 3
    )

    /// As many rows on screen as legibility allows.
    static let dense = CloudTreeStyle(
        id: "dense", name: "Dense",
        rowHeight: 17, machineRowLayout: .singleLine,
        machineNameSize: 11, titleSize: 11, detailSize: 9.5, groupLabelSize: 10,
        iconSize: 9, iconSlot: 12, iconGap: 5, iconTint: .monochrome,
        showsGroupCounts: false, showsViewBadges: true, showsMachineStats: false,
        machineVerticalPadding: 2
    )

    /// Finder sidebar: single line, larger tinted glyphs, folder-blue workspaces.
    static let finder = CloudTreeStyle(
        id: "finder", name: "Finder",
        rowHeight: 22, machineRowLayout: .singleLine,
        machineNameSize: 12.5, titleSize: 12, detailSize: 10.5, groupLabelSize: 11,
        iconSize: 12, iconSlot: 18, iconGap: 6, iconTint: .tinted,
        showsGroupCounts: true, showsViewBadges: true, showsMachineStats: false,
        machineVerticalPadding: 3
    )

    /// Structure from indentation alone: no leaf glyphs, no counts, quiet text.
    static let minimal = CloudTreeStyle(
        id: "minimal", name: "Minimal",
        rowHeight: 19, machineRowLayout: .singleLine,
        machineNameSize: 12, titleSize: 11.5, detailSize: 10, groupLabelSize: 10.5,
        iconSize: 0, iconSlot: 0, iconGap: 0, iconTint: .monochrome,
        showsGroupCounts: false, showsViewBadges: true, showsMachineStats: false,
        machineVerticalPadding: 3
    )

    /// Gallery order. `compact` is the shipped default.
    static let presets: [CloudTreeStyle] = [.compact, .classic, .dense, .finder, .minimal]

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
