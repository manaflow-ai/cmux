import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import QuartzCore
import Testing

/// DIAG (nomerge, PIN MOTION 7): why the pinned item of an out-of-view block flies to a 0x0 frame.
@MainActor @Suite(.serialized, .closesItsWindows, .enabled(if: !NSScreen.screens.isEmpty))
struct SidebarPinScrollDiagTests {
    static func anims(_ layer: CALayer?) -> [String] {
        (layer?.animationKeys() ?? []).compactMap { key -> String? in
            guard let a = layer?.animation(forKey: key) else { return key }
            let begin = layer.map { $0.convertTime(a.beginTime, to: nil) } ?? 0
            if let b = a as? CABasicAnimation {
                return "\(key) \(b.keyPath ?? "") from \(String(describing: b.fromValue)) to \(String(describing: b.toValue)) additive \(b.isAdditive) begin \(begin - CACurrentMediaTime())"
            }
            return "\(key) \(type(of: a)) begin \(begin - CACurrentMediaTime())"
        }
    }

    static func dump(_ label: String, _ list: SidebarListView) {
        let key = SidebarRowKey.block(SidebarLayoutDocument.pinnedSectionID.rawValue)
        var lines = ["DIAG \(label): clip \(list.enclosingScrollView?.contentView.bounds ?? .zero) list frame \(list.frame) list anims \(anims(list.layer)) clip anims \(anims(list.enclosingScrollView?.contentView.layer))"]
        for case let row as SidebarRowView in list.subviews where row.key == .workspace(SidebarPinFlightTests.moved) {
            lines.append("DIAG \(label): row d frame \(row.frame) hidden \(row.isHidden) anims \(anims(row.layer)) drawn \(list.drawnFrame(of: row))")
        }
        lines += ["DIAG \(label): rowViews block \(list.rowViews[key].map { "\($0.frame) hidden \($0.isHidden)" } ?? "none")"]
        for case let block as SidebarBlockRowView in list.subviews {
            let region = block.region
            lines.append("DIAG \(label):  block anims \(anims(block.layer)) z \(block.layer?.zPosition ?? 0) layerframe \(block.layer?.frame ?? .zero) superlayer ok \(block.layer?.superlayer === list.layer) region anims \(anims(region.layer)) region layerframe \(region.layer?.frame ?? .zero) drawn \(list.drawnFrame(of: block))")
            lines.append("DIAG \(label):  block view \(ObjectIdentifier(block)) key \(block.key) frame \(block.frame) hidden \(block.isHidden) targetSize \(block.targetSize) region frame \(region.frame) rows \(region.layoutResult.rows.map { "\($0.kind) \($0.frame)" })")
            for (id, item) in region.itemViews {
                let layer = item.layer
                let anims = (layer?.animationKeys() ?? []).compactMap { key -> String? in
                    guard let a = layer?.animation(forKey: key) as? CABasicAnimation else { return key }
                    return "\(key) \(a.keyPath ?? "") from \(String(describing: a.fromValue)) to \(String(describing: a.toValue)) additive \(a.isAdditive)"
                }
                lines.append("DIAG \(label):   item \(id.rawValue) ws \(item.info.workspace?.rawValue ?? "-") frame \(item.frame) layer \(layer?.frame ?? .zero) hidden \(item.isHidden) in region \(item.superview === region) anims \(anims) drawn \(list.drawnFrame(of: item)) drawn+0.2 \(list.drawnFrame(of: item, now: CACurrentMediaTime() + 0.2))")
            }
        }
        print(lines.joined(separator: "\n"))
    }

    @Test func diagPinToABlockOutOfView() throws {
        let (list, scroll, window) = SidebarPinFlightTests.scrolledList(pins: [])
        defer { window.close() }
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        Self.dump("built", list)
        let row = try #require(list.displayed.row(for: .workspace(SidebarPinFlightTests.moved)).map { list.frame(for: $0) })
        scroll.contentView.scroll(to: NSPoint(x: 0, y: row.minY - 100))
        scroll.reflectScrolledClipView(scroll.contentView)
        list.realizeVisibleRows()
        list.layoutSubtreeIfNeeded()
        Self.dump("scrolled", list)
        SidebarPinFlightTests.show([SidebarPinFlightTests.moved], listed: SidebarPinFlightTests.long, on: list)
        list.reload(animated: true)
        Self.dump("after reload", list)
        let probes = SidebarPinFlightTests.probes(SidebarPinFlightTests.moved, list, now: CACurrentMediaTime())
        for tick in [0, 1, 5, 20, 34] { print("DIAG probe tick \(tick): \(probes.map { "\(type(of: $0.view)) rest \($0.rest) shown \(String(describing: $0.shown(at: CACurrentMediaTime() + Double(tick) / 120)))" })") }
        list.layoutSubtreeIfNeeded()
        Self.dump("after layout", list)
    }
}
