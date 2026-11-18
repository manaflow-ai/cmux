import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import QuartzCore
import Testing

/// Leo 2026-11-08 (ask-785331b491): "there's the sidebar where when things maybe open or shift a bit, there's like still a
/// bit of a flicker on that, like individual top group". A top section of the sidebar document (Pinned here) draws as one
/// block row of the list. Its fold reloaded the whole list (every listed row laid out, every realized row configured),
/// took the section's items away in the first frame of a close and drew them at once over the rows below on an open.
/// The fold moves the block row and the rows below it now (`SidebarListView.foldBlock`), the same work at 10,000 rows as
/// at 100, and the block clips its items to its springing frame (`SidebarRegionFoldMove`).
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(5))) struct SidebarSectionFoldTests {
    static let pinned = SidebarLayoutDocument.pinnedSectionID
    static let blockKey = SidebarRowKey.block(pinned.rawValue)

    final class Harness {
        let model: SidebarModel
        let sidebar: SidebarView
        let window: NSWindow
        var list: SidebarListView { sidebar.list }
        var block: SidebarBlockRowView? { list.rowViews[SidebarSectionFoldTests.blockKey] as? SidebarBlockRowView }

        /// A Pinned block of 6 items over `rows` loose workspaces, in a 260 x 900 window.
        init(rows: Int) {
            _ = NSApplication.shared
            let items = (0..<6).map { LayoutItemID("itm_sfold_\($0)") }
            let pinned = LayoutSection(id: SidebarSectionFoldTests.pinned, title: "Pinned", region: .top, look: .builtIn, arrangement: .list,
                                       items: items.map { LayoutItem(id: $0, ref: .workspace("s:\($0.rawValue)")) })
            let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
            let nodes = (0..<rows).map { SidebarNode.workspace(SidebarWorkspace(id: WorkspaceID("sfold-\($0)"), title: "Workspace \($0)")) }
            let blockSection = SidebarSection(kind: .custom(SidebarCustomSection(id: SidebarSectionFoldTests.pinned.rawValue)), nodes: [])
            model = SidebarModel(sections: [blockSection, SidebarSection(kind: .machine(machine), nodes: nodes)])
            model.docDrag = SidebarDocDrag(item: { _ in nil }, section: { _ in nil }, begin: { _ in [:] }, drop: { _, _ in }, adoptRef: { _ in nil })
            model.layout = SidebarLayoutDocument(sections: [pinned])
            model.itemInfo = Dictionary(uniqueKeysWithValues: items.map { id in
                var info = SidebarItemInfo(title: id.rawValue, symbol: "terminal")
                info.workspace = WorkspaceID("ws-\(id.rawValue)")
                return (id, info)
            })
            sidebar = SidebarView(model: model, design: DesignSettings())
            sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 900)
            window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = sidebar
            window.orderFrontRegardless()
            sidebar.renderNow()
            settle()
            list.reload(animated: false)
            settle()
        }

        func settle() {
            sidebar.bandsDirty = true
            sidebar.needsLayout = true
            sidebar.layoutSubtreeIfNeeded()
            list.fitToClip()
            sidebar.layoutSubtreeIfNeeded()
        }

        /// The person folds or opens Pinned (its header's click), and the sidebar takes it at its next layout.
        func toggle() {
            model.noteUserIntent()
            model.send(.toggleLayoutSection(SidebarSectionFoldTests.pinned))
            sidebar.bandsDirty = true
            sidebar.needsLayout = true
            sidebar.layoutSubtreeIfNeeded()
        }

        /// The first loose row under the block: its y in the list's layout.
        var firstRowY: CGFloat? { list.displayed.row(for: .workspace(WorkspaceID("sfold-0")))?.y }
    }

    /// What one toggle did to the list.
    struct Work: CustomStringConvertible {
        var reloads = 0, layoutRows = 0, blockFolds = 0, rowConfigures = 0, rowViewsMade = 0, realized = 0, realizedAfter = 0
        var walked = 0, laidOut = 0
        var description: String {
            "(reloads: \(reloads), layout_rows: \(layoutRows), block_folds: \(blockFolds), row_configures: \(rowConfigures), realized: \(realized) -> \(realizedAfter), "
                + "row_views_made: \(rowViewsMade), list rows walked: \(walked), list rows laid out: \(laidOut))"
        }
    }

    static func toggle(_ h: Harness) -> Work {
        _ = SidebarPerfCounters.report(reset: true)
        _ = h.list.listWork.take()
        var work = Work()
        work.realized = h.list.rowViews.count
        h.toggle()
        let r = SidebarPerfCounters.report(reset: true)
        (work.reloads, work.layoutRows, work.blockFolds) = (r["list_reloads"] ?? 0, r["layout_rows"] ?? 0, r["block_folds"] ?? 0)
        (work.rowConfigures, work.rowViewsMade) = (r["row_configures"] ?? 0, r["row_views_made"] ?? 0)
        let meter = h.list.listWork.take()
        (work.walked, work.laidOut, work.realizedAfter) = (meter.itemsWalked, meter.rowsLaidOut, h.list.rowViews.count)
        return work
    }

    /// A fold and an open of Pinned: no list reload, no row laid out outside the block, at 100 rows as at 10,000; the rows
    /// under the block move by its height change and come back.
    @Test(arguments: [100, 10_000])
    func aSectionFoldReloadsNothing(_ rows: Int) throws {
        let h = Harness(rows: rows)
        defer { h.window.closeAfterTest() }
        let open = try #require(h.block?.frame.height, "the list draws no Pinned block")
        let y = try #require(h.firstRowY)
        let close = Self.toggle(h)
        let closedHeight = try #require(h.list.displayed.row(for: Self.blockKey)?.height)
        let closedY = try #require(h.firstRowY)
        let reopen = Self.toggle(h)
        print("section-fold n=\(rows) close=\(close)")
        print("section-fold n=\(rows) open=\(reopen)")
        #expect(closedHeight < open, "Pinned's block kept its height \(open) closed")
        #expect(closedY == y - (open - closedHeight), "the rows under the block moved from \(y) to \(closedY), the block by \(open - closedHeight)")
        #expect(h.firstRowY == y, "the rows under the block did not come back")
        for (phase, work) in [("close", close), ("open", reopen)] {
            #expect(work.reloads == 0, "\(phase) reloaded the list: \(work)")
            #expect(work.layoutRows == 0 && work.walked == 0 && work.laidOut == 0, "\(phase) laid out the list's rows: \(work)")
            // The block, and the rows a close brings into view (their new views).
            #expect(work.rowConfigures <= 1 + max(0, work.realizedAfter - work.realized), "\(phase) configured rows already shown: \(work)")
        }
    }

    /// The fold frame by frame, as the render server shows it (presented frames, display only): closing, the items stay
    /// in the slot while it closes (no frame shows the header over an empty slot); opening, no item draws past the
    /// block's frame onto the rows below.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func aSectionFoldFrameByFrame() throws {
        let oldReduceMotion = Motion.reduceMotionOverride
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = oldReduceMotion }
        let h = Harness(rows: 40)
        defer { h.window.closeAfterTest() }
        let block = try #require(h.block, "the list draws no Pinned block")
        let header = try #require(block.region.layoutResult.rows.first { if case .header = $0.kind { true } else { false } }?.frame.height)
        let out = AANestedGroupsGalleryTests.packageRoot.appending(path: "section-fold-frames")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for phase in ["close", "open"] {
            h.toggle()
            let start = Date()
            var frame = 0, empty = 0, overdraw = 0
            while Date().timeIntervalSince(start) < Motion.sidebar.spring(.move).settlingTime() + 0.15 {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0 / 60))
                let shown = block.layer?.presentation()?.frame ?? block.frame
                let clips = block.clipsToBounds
                // Item views drawn in the block, in list coordinates (their presented frames inside the block's).
                let items = block.region.subviews.compactMap { $0 as? SidebarItemRowView }.filter { !$0.isHidden && $0.alphaValue > 0 }
                let frames = items.map { ($0.layer?.presentation()?.frame ?? $0.frame).offsetBy(dx: shown.minX, dy: shown.minY) }
                let inSlot = frames.filter { $0.minY < shown.maxY - 0.5 && $0.maxY > shown.minY + header }.count
                let past = clips ? 0 : frames.filter { $0.maxY > shown.maxY + 0.5 }.count
                if shown.height > header + 2, inSlot == 0 { empty += 1 }
                if past > 0 { overdraw += 1 }
                print("section-fold-frame \(phase) \(frame): block=\(Int(shown.height)) items=\(items.count) inSlot=\(inSlot) clips=\(clips) past=\(past)")
                if frame % 3 == 0, let image = Self.presented(h.sidebar) {
                    try? AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(phase)-\(String(format: "%02d", frame)).png"))
                }
                frame += 1
            }
            print("section-fold-frames \(phase): frames=\(frame) emptySlot=\(empty) overdraw=\(overdraw)")
            #expect(empty == 0, "\(phase): \(empty) frames showed Pinned's header over an empty slot")
            #expect(overdraw == 0, "\(phase): \(overdraw) frames drew Pinned's items past its block onto the rows below")
        }
    }

    /// The sidebar as the render server shows it now (its presentation layers).
    static func presented(_ view: NSView) -> CGImage? {
        guard let layer = view.layer?.presentation() ?? view.layer else { return nil }
        let scale = view.window?.backingScaleFactor ?? 2
        let size = view.bounds.size
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        if view.isFlipped {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        return context.makeImage()
    }
}
