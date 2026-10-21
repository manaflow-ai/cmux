import AppKit
@testable import CmuxNextApp
@testable import CmuxNextLayout
import Testing

// Scratch probes for the NSWindow weak-reference abort (not for merge).
@MainActor
struct ZZNSWindowProbeTests {
    static var kept: [AnyObject] = []

    private static func strip() -> PaneCloseMotionTests.Screen {
        PaneCloseMotionTests.Screen(.columns([LayoutColumn(id: "c1", width: 0.5, root: .leaf("p1")),
                                              LayoutColumn(id: "c2", width: 0.5, root: .split("v", axis: .vertical, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3")))]))
    }

    @Test func zzProbeNoSiblingKeptAlive() {
        let lone = PaneCloseMotionTests.Screen(.splits(.leaf("p1")))
        _ = lone.close("p1")
        let strip = Self.strip()
        _ = strip.close("p1")
        _ = strip.close("p2")
        Self.kept += [lone, strip]
    }

    @Test func zzProbeLoneOnly() {
        let lone = PaneCloseMotionTests.Screen(.splits(.leaf("p1")))
        _ = lone.close("p1")
    }

    @Test func zzProbeStripCloses() {
        let strip = Self.strip()
        _ = strip.close("p1")
        _ = strip.close("p2")
    }

    @Test func zzProbeStripCreateOnly() {
        _ = Self.strip()
    }

    @Test func zzProbeStripCreateContentNil() {
        let strip = Self.strip()
        strip.window.contentView = nil
    }

    @Test func zzProbeSwipeKeptAlive() throws {
        let w = PaneHorizontalScrollClaimTests.Window()
        try #require(w.table).claims = false
        _ = w.swipe(at: try w.point(inP1: 0.25))
        _ = w.scroll(at: try w.point(inP1: 0.25), dx: -1, units: .line)
        Self.kept.append(w)
    }

    @Test func zzProbeSwipeOnly() throws {
        let w = PaneHorizontalScrollClaimTests.Window()
        try #require(w.table).claims = false
        _ = w.swipe(at: try w.point(inP1: 0.25))
    }

    @Test func zzProbeLineScrollOnly() throws {
        let w = PaneHorizontalScrollClaimTests.Window()
        try #require(w.table).claims = false
        _ = w.scroll(at: try w.point(inP1: 0.25), dx: -1, units: .line)
    }

    @Test func zzProbeClaimWindowOnly() {
        _ = PaneHorizontalScrollClaimTests.Window()
    }
}
