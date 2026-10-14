import AppKit
import CmuxNextDesign

/// Title-fitted widths for `.chrome` strips. The drawn layout and the drop
/// math both apply them, so a drop resolves against the tabs as drawn (cx-6ggef).
enum TabTitleWidths {
    static func apply(to items: inout [TabLayoutItem], tabs: [TabItem], style: TabStripStyle, metrics: TabStripMetrics) {
        guard style == .chrome else { return }
        let titles = Dictionary(tabs.map { ($0.id, $0.title.isEmpty ? Strings.untitled : $0.title) }, uniquingKeysWith: { first, _ in first })
        let font = Typography.body
        for index in items.indices where !items[index].isPinned && !items[index].isGroupChip && items[index].fixedWidth == nil {
            guard let title = titles[items[index].id] else { continue }
            let width = ceil((title as NSString).size(withAttributes: [.font: font]).width)
            items[index].naturalWidth = metrics.naturalTabWidth(titleWidth: width)
        }
    }
}
