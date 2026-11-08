import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import QuartzCore
import Testing

/// DIAG ONLY (fix/pin-tabmask-diag-nomerge, never merges): per tick, the frames `TabPinMotionTests` reads for the
/// flying pill and every other tab, in the strip's root layer coordinates (window space), next to what Core Animation's
/// own presentation tree shows when the run loop runs, so a coordinate mismatch in the test and a wrong mask in the
/// code read apart.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct TabPinMaskDiagTests {
    @Test(.enabled("the strip animates only in a window on a screen") { await TabPinMotionTests.hasDisplay() })
    func diagPin() async throws { try await Self.diag(pin: true) }

    @Test(.enabled("the strip animates only in a window on a screen") { await TabPinMotionTests.hasDisplay() })
    func diagUnpin() async throws { try await Self.diag(pin: false) }

    static func text(_ rect: CGRect) -> String { String(format: "[%.1f..%.1f w%.1f]", rect.minX, rect.maxX, rect.width) }

    /// The x overlap of two rects (the y of two regions' layers may differ).
    static func across(_ a: CGRect, _ b: CGRect) -> String { String(format: "%.1f", max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))) }

    static func diag(pin: Bool) async throws {
        let name = pin ? "pin" : "unpin"
        let first = TabPinMotionTests.ids[0], moved = TabPinMotionTests.moved
        let (strip, model, window) = try TabPinMotionTests.strip(pinned: pin ? [first] : [first, moved])
        defer { window.closeAfterTest() }
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let root = try #require(strip.layer)
        let clip = try #require(strip.tabsClip.layer)
        let cell = try #require(strip.cells[moved])
        func where_(_ layer: CALayer?) -> String {
            layer === strip.scrollingLayer ? "scrolling" : layer === clip ? "tabsClip" : "other"
        }
        let ids = TabPinMotionTests.ids
        func layers(_ tag: String) {
            print("diag-tabmask \(name) \(tag): clip frame \(clip.frame) bounds \(clip.bounds) flipped \(clip.isGeometryFlipped)"
                + " scrolling frame \(strip.scrollingLayer.frame) bounds \(strip.scrollingLayer.bounds)"
                + " masks \(strip.scrollingLayer.masksToBounds) scroll keys \(strip.scrollingLayer.animationKeys() ?? [])"
                + " clip keys \(clip.animationKeys() ?? []) pinFlights \(strip.pinFlights.map(\.rawValue).sorted())"
                + " occlusionEnds \(strip.occlusionEnds.keys.map(\.rawValue).sorted())")
            for id in ids {
                guard let c = strip.cells[id], let parent = c.layer.superlayer else { continue }
                let mask = c.layer.mask
                print("diag-tabmask \(name) \(tag): \(id.rawValue) in \(where_(parent)) pinned \(c.item.isPinned) frame \(text(c.layer.frame))"
                    + " root \(text(parent.convert(c.layer.frame, to: root))) z \(c.layer.zPosition) keys \(c.layer.animationKeys() ?? [])"
                    + " mask \(mask.map { "\(text($0.frame)) occl \($0 === c.occlusionMaskIfMade) keys \($0.animationKeys() ?? [])" } ?? "nil")")
            }
        }
        layers("before")
        model.tabs = TabPinMotionTests.tabs(pinned: pin ? [first, moved] : [first])
        strip.sync(fromModel: true)
        let begin = try #require(TabMoveMotionTargetTests.moveBegin(Array(strip.cells.values)), "the pin did not animate")
        print("diag-tabmask \(name): sync returned \(String(format: "%.2f", (CACurrentMediaTime() - begin) * 1000)) ms after the move's begin")
        layers("after")
        for id in ids {
            guard let c = strip.cells[id] else { continue }
            for key in c.layer.mask?.animationKeys() ?? [] {
                guard let a = c.layer.mask?.animation(forKey: key) else { continue }
                let b = c.layer.mask!.convertTime(a.beginTime, to: nil)
                print("diag-tabmask \(name): \(id.rawValue) mask \(key) begins \(String(format: "%.2f", (b - begin) * 1000)) ms, lasts \(a.duration)")
            }
        }
        // The test's reading, per tick: layer-local (what the test intersects) and converted to the root through each
        // layer's own superlayer (window space).
        let ticks = MotionPath.sampleCount(seconds: 0.4)
        for k in 0...ticks {
            let time = begin + Double(k) / 120
            let frame = TabPinMotionTests.shown(cell, at: time)
            let pill = cell.metrics.pillFrame(slotWidth: frame.width, height: frame.height).offsetBy(dx: frame.minX, dy: 0)
            let pillRoot = cell.layer.superlayer.map { $0.convert(pill, to: root) } ?? pill
            var line = "diag-tabmask \(name) model tick \(k): pill local \(text(pill)) root \(text(pillRoot))"
            for id in ids where id != moved {
                guard let other = strip.cells[id], let parent = other.layer.superlayer else { continue }
                let f = TabPinMotionTests.shown(other, at: time)
                var visible = f
                if let mask = other.layer.mask {
                    let center = MotionPath(mask, "position").value(at: time), size = MotionPath(mask, "bounds.size").value(at: time)
                    visible = CGRect(x: f.minX + center.x - size.x / 2, y: 0, width: size.x, height: f.height)
                }
                let visibleRoot = parent.convert(visible, to: root)
                line += " | \(id.rawValue) local \(text(visible)) root \(text(visibleRoot)) through local \(across(visible, pill)) root \(across(visibleRoot, pillRoot))"
            }
            print(line)
        }
        // Core Animation's own answer: the presentation tree while the run loop runs.
        var last = -1
        while CACurrentMediaTime() < begin + 0.45 {
            try await Task.sleep(for: .milliseconds(2))
            let now = CACurrentMediaTime()
            let k = Int(((now - begin) * 120).rounded(.down))
            guard k != last else { continue }
            last = k
            guard let shownCell = cell.layer.presentation(), let parent = cell.layer.superlayer else { continue }
            let parentShown = parent.presentation() ?? parent
            let rootShown = root.presentation() ?? root
            let frame = shownCell.frame
            let pill = cell.metrics.pillFrame(slotWidth: frame.width, height: frame.height).offsetBy(dx: frame.minX, dy: 0)
            let pillRoot = parentShown.convert(pill, to: rootShown)
            var line = String(format: "diag-tabmask \(name) real t %.2f ticks: pill root %@", (now - begin) * 120, text(pillRoot))
            for id in ids where id != moved {
                guard let other = strip.cells[id], let p = other.layer.presentation(), let op = other.layer.superlayer else { continue }
                let opShown = op.presentation() ?? op
                var visible = p.frame
                if let mask = other.layer.mask {
                    let m = mask.presentation() ?? mask
                    visible = CGRect(x: p.frame.minX + m.frame.minX, y: 0, width: m.frame.width, height: p.frame.height)
                }
                let visibleRoot = opShown.convert(visible, to: rootShown)
                line += " | \(id.rawValue) root \(text(visibleRoot)) through \(across(visibleRoot, pillRoot))"
            }
            print(line)
        }
    }
}
