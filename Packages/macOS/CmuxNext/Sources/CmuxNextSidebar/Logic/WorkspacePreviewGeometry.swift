import Foundation
import CmuxNextResources

/// The shaped preview's pane rects, from the Rust rule (`cmux-layout-reducer::workspace_preview`). The answer depends on
/// the layout and the width only, so samples that arrive later fill reserved room and never move a pane or a row.
nonisolated struct WorkspacePreviewGeometry: Decodable, Equatable {
    enum Stats: String, Decodable { case both, one, none }

    struct Pane: Decodable, Equatable {
        var id: String
        var x: Double
        var y: Double
        var w: Double
        var h: Double
        var shown: [Int]
        var more: Int
        var stats: Stats
        var collapsed: Bool
    }

    var width: Double
    var height: Double
    var panes: [Pane]

    /// The card's sizes, from its tokens.
    struct Metrics: Encodable, Equatable {
        var gap: Double
        var inset: Double
        var row: Double
        var row_gap: Double
        var min_width: Double
        var max_height: Double
        var max_rows: Int
        var stats_both: Double
        var stats_one: Double
        var title_min: Double
        var icon: Double
    }

    private struct Request: Encodable {
        struct Pane: Encodable { var id: String; var tabs: Int; var active: Int }
        var layout: SidebarPaneLayout.Node
        var panes: [Pane]
        var width: Double
        var aspect: Double
        var metrics: Metrics
    }

    /// The rects for `layout` at `width`; nil when the reducer refuses it.
    static func make(_ layout: SidebarPaneLayout, width: Double, aspect: Double, metrics: Metrics) -> WorkspacePreviewGeometry? {
        let request = Request(layout: layout.root,
                              panes: layout.panes.map { .init(id: $0.id, tabs: $0.tabs.count, active: $0.active) },
                              width: width, aspect: aspect, metrics: metrics)
        return RustSidebarClient.call("workspace_preview", request, as: WorkspacePreviewGeometry.self)
    }

    /// A tab's numbers, short enough for a preview row: CPU as whole percent ("12%"), memory in one or two
    /// significant figures with a one-letter unit ("840M", "1.2G"). A dash holds the room until a sample exists.
    static func cpuText(_ usage: ResourceUsage?) -> String {
        guard let cpu = usage?.cpu else { return "–" }
        let percent = max(0, cpu * 100)
        return percent < 1 && percent > 0 ? "<1%" : "\(Int(percent.rounded()))%"
    }

    static func memoryText(_ usage: ResourceUsage?) -> String {
        guard let bytes = usage?.memoryBytes, bytes > 0 else { return "–" }
        let mb = Double(bytes) / 1_048_576
        if mb < 1000 { return "\(Int(mb.rounded()))M" }
        let gb = mb / 1024
        return gb < 10 ? String(format: "%.1fG", gb) : "\(Int(gb.rounded()))G"
    }
}
