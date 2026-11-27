import CCmuxLayoutCacheFFI
import CmuxNextDesign
import Foundation
import Testing

/// Main-thread ms one layout-cache write costs (`LayoutCacheWriter`), before and after the encode
/// moved off the main actor, in one harness. Before: the drain encoded the document, compared it with
/// the last write and handed it to Rust's `coalescer_wrote` (parse, cap, hash), all on main. After:
/// main records the key the off-main keyed write returned (`coalescer_wrote_key`). The gather of
/// window values is main-thread work in both and is not counted. Duress: a near-cap document
/// (48 windows of 64 panes) with every core but one kept busy.
@MainActor struct LayoutCacheWriteMainThreadCostTests {
    final class Spin: @unchecked Sendable { var stop = false }

    static func document(windows: Int, panes: Int) -> LayoutCacheDocument {
        let rect = LayoutCacheRect(x: 0, y: 0, width: 1440, height: 900)
        let windows = (0..<windows).map { w in
            let leaves = (0..<panes).map { p in
                LayoutCachePaneNode.leaf(LayoutCacheLeaf(paneId: "pane-\(w)-\(p)", kind: .terminal,
                                                         frame: LayoutCacheRect(x: Double(p), y: 0, width: 200, height: 300)))
            }
            return LayoutCacheWindow(id: "window-\(w)", frame: rect, displayId: 1, backingScale: 2, fullscreen: false, alpha: 1,
                                     appearance: .dark, theme: LayoutCacheTheme(backgroundRgba: [10, 10, 10, 255], barRgba: [20, 20, 20, 255]),
                                     sidebar: LayoutCacheSidebar(width: 240, collapsed: false), workspaceId: "ws-\(w)", tabId: "",
                                     tabStrip: [], panes: .split(horizontal: true, fractions: leaves.map { _ in 1 / Double(panes) }, children: leaves))
        }
        return LayoutCacheDocument(buildKey: "bench", displays: [LayoutCacheDisplay(id: 1, frame: rect, backingScale: 2)], windows: windows)
    }

    static func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    static func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    func measure(_ label: String, windows: Int, panes: Int) throws -> (before: Double, after: Double) {
        let document = Self.document(windows: windows, panes: panes)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("layout-cache-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("v1.json").path
        let coalescer = try #require(cmux_layout_cache_coalescer_new())
        defer { cmux_layout_cache_coalescer_free(coalescer) }
        let clock = ContinuousClock()
        var before: [Double] = [], after: [Double] = [], bytes = 0
        var previous = ""
        for round in 0..<40 {
            cmux_layout_cache_coalescer_note(coalescer, UInt64(round * 10))
            let old = clock.measure {
                let json = LayoutCacheFFI.json(document) ?? ""
                if json != previous { previous = json }
                _ = cmux_layout_cache_coalescer_wrote(coalescer, json)
            }
            before.append(Self.ms(old))
            bytes = previous.utf8.count

            cmux_layout_cache_coalescer_note(coalescer, UInt64(round * 10 + 5))
            // Off main in the app (BackgroundWork's files lane): the encode and the keyed write.
            var key: UInt64 = 0
            #expect(cmux_layout_cache_write_keyed(path, LayoutCacheFFI.json(document) ?? "", &key) == 0)
            let new = clock.measure { _ = cmux_layout_cache_coalescer_wrote_key(coalescer, key) }
            after.append(Self.ms(new))
            #expect(cmux_layout_cache_coalescer_next_due_ms(coalescer) == -1)
        }
        let result = (before: Self.median(before), after: Self.median(after))
        print("layout-cache-main-ms \(label) windows=\(windows) panes=\(panes) json_bytes=\(bytes) "
              + "before_median_ms=\(String(format: "%.4f", result.before)) after_median_ms=\(String(format: "%.4f", result.after)) "
              + "before_max_ms=\(String(format: "%.4f", before.max() ?? 0)) after_max_ms=\(String(format: "%.4f", after.max() ?? 0))")
        return result
    }

    @Test func mainThreadMsBeforeAndAfter() throws {
        let typical = try measure("typical", windows: 3, panes: 8)
        #expect(typical.after < typical.before)

        let spin = Spin()
        let busy = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
        for _ in 0..<busy {
            Thread.detachNewThread { var x: UInt64 = 0; while !spin.stop { x &+= 1 } }
        }
        defer { spin.stop = true }
        let duress = try measure("duress(\(busy) busy cores)", windows: 48, panes: 64)
        #expect(duress.after < duress.before)
    }
}
