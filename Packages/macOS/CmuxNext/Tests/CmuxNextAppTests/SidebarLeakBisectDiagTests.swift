import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

// DIAG (scratch only, never lands): which build step of PinnedRowsShareHomeColumnTests.list keeps the closed window
// and list alive. Prints one BISECT line per variant.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarLeakBisectDiagTests {
    struct Weak { weak var object: AnyObject? }

    static func report(_ name: String, _ refs: [String: Weak]) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let parts = refs.keys.sorted().map { "\($0)=\(refs[$0]?.object == nil ? "freed" : "ALIVE")" }
        print("BISECT \(name) " + parts.joined(separator: " "))
    }

    static func window(scale: CGFloat) -> NSWindow {
        let window = PinnedRowsShareHomeColumnTests.ScaledWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 600),
                                                                 styleMask: [.borderless], backing: .buffered, defer: false)
        window.testScale = scale
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        return window
    }

    static func model() -> SidebarModel {
        let top = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, arrangement: .list,
                                items: [PinnedRowsShareHomeColumnTests.home])
        let pinned = SidebarLayoutDocument.pinnedSection(items: PinnedRowsShareHomeColumnTests.pins)
        return SidebarModel(sections: [
            SidebarSection(kind: .custom(SidebarCustomSection(id: top.id.rawValue)), nodes: []),
            SidebarSection(kind: .custom(SidebarCustomSection(id: pinned.id.rawValue)), nodes: []),
        ])
    }

    static func blocks(_ list: SidebarListView) {
        let top = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, arrangement: .list,
                                items: [PinnedRowsShareHomeColumnTests.home])
        let pinned = SidebarLayoutDocument.pinnedSection(items: PinnedRowsShareHomeColumnTests.pins)
        var metrics = SidebarRegionMetrics.standard
        metrics.trailingTrim = SidebarStyle.rowTrailingTrim
        list.blocks = SidebarListBlocks(sections: [top.id.rawValue: top, pinned.id.rawValue: pinned],
                                        infos: PinnedRowsShareHomeColumnTests.infos(), collapsed: [],
                                        look: .quiet, metrics: metrics, drawsLines: false, appHeights: [:])
    }

    @Test func bisect() throws {
        _ = NSApplication.shared
        var refs: [String: Weak] = [:]

        autoreleasepool {
            let w = Self.window(scale: 2); w.orderFrontRegardless(); refs = ["window": Weak(object: w)]; w.close()
        }
        Self.report("A-window-only", refs)

        autoreleasepool {
            let l = SidebarListView(model: Self.model()); refs = ["list": Weak(object: l)]
        }
        Self.report("B-list-no-window", refs)

        autoreleasepool {
            let l = SidebarListView(model: Self.model()); Self.blocks(l); refs = ["list": Weak(object: l)]
        }
        Self.report("B2-list-blocks-no-window", refs)

        autoreleasepool {
            let w = Self.window(scale: 2); let l = SidebarListView(model: Self.model())
            l.frame = w.contentView!.bounds; w.contentView!.addSubview(l); w.orderFrontRegardless()
            refs = ["window": Weak(object: w), "list": Weak(object: l)]; w.close()
        }
        Self.report("C-in-window-no-blocks", refs)

        autoreleasepool {
            let w = Self.window(scale: 2); let l = SidebarListView(model: Self.model()); Self.blocks(l)
            l.frame = w.contentView!.bounds; w.contentView!.addSubview(l); w.orderFrontRegardless()
            refs = ["window": Weak(object: w), "list": Weak(object: l)]; w.close()
        }
        Self.report("D-blocks-in-window-no-reload", refs)

        autoreleasepool {
            let w = Self.window(scale: 2); let l = SidebarListView(model: Self.model()); Self.blocks(l)
            l.frame = w.contentView!.bounds; w.contentView!.addSubview(l); w.orderFrontRegardless()
            l.reload(animated: false)
            refs = ["window": Weak(object: w), "list": Weak(object: l)]; w.close()
        }
        Self.report("E-reload", refs)

        autoreleasepool {
            let w = Self.window(scale: 2); let l = SidebarListView(model: Self.model()); Self.blocks(l)
            l.frame = w.contentView!.bounds; w.contentView!.addSubview(l); w.orderFrontRegardless()
            l.reload(animated: false); l.layoutSubtreeIfNeeded()
            refs = ["window": Weak(object: w), "list": Weak(object: l)]; w.close()
        }
        Self.report("F-reload-layout", refs)

        autoreleasepool {
            let (l, w) = PinnedRowsShareHomeColumnTests.list(scale: 2)
            var r = ["window": Weak(object: w), "list": Weak(object: l)]
            for region in l.blockRegions {
                for (key, item) in region.itemViews {
                    r["item-\(key.rawValue)"] = Weak(object: item)
                    r["ind-\(key.rawValue)"] = Weak(object: item.activity)
                }
            }
            refs = r; w.close()
        }
        Self.report("G-full-list", refs)

        autoreleasepool {
            let (l, w) = PinnedRowsShareHomeColumnTests.list(scale: 2)
            refs = ["window": Weak(object: w), "list": Weak(object: l)]
            l.removeFromSuperview(); w.close()
        }
        Self.report("H-full-list-removed-first", refs)

        let c = PinnedRowsShareHomeColumnTests.Case(density: .compact, minimal: .off, textSize: .standard, scale: 2)
        try PinnedRowsShareHomeColumnTests.at(c) {
            autoreleasepool {
                let (l, w) = PinnedRowsShareHomeColumnTests.list(scale: 2)
                refs = ["window": Weak(object: w), "list": Weak(object: l)]; w.close()
            }
        }
        Self.report("I-full-list-in-at", refs)
    }
}
