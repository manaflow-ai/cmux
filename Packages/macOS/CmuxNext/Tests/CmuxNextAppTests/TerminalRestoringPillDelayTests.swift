import AppKit
@testable import CmuxNextTerminal
import QuartzCore
import Testing

/// Lawrence's restore targets (2026-10-27, binding): no "Restoring…" pill on a visible pane unless its attach is
/// still missing after 1 s, and then over the last content. The pill faded in after 0.5 s, so an attach that
/// answered in 0.5-1 s (a warm relaunch with 60 workspaces: 0.4-0.5 s to live on the optimized build, more on a
/// loaded Mac) flashed it.
@MainActor struct TerminalRestoringPillDelayTests {
    @Test func theRestoringPillShowsOnlyAfterTheAttachIsMissingForASecond() throws {
        let banner = TerminalStatusBanner()
        banner.wantsLayer = true
        let layer = try #require(banner.layer)
        let before = layer.convertTime(CACurrentMediaTime(), from: nil)
        banner.show(.restoring)
        #expect(!banner.isHidden)
        let fade = try #require(layer.animation(forKey: "terminalStatus.restoringReveal"), "the pill has no delayed reveal")
        let hold = try #require(layer.animation(forKey: "terminalStatus.restoringHold") as? CABasicAnimation)
        #expect((hold.toValue as? NSNumber)?.doubleValue == 0, "the pill is not held clear while it waits")
        #expect(fade.beginTime - before >= 1.0, "the pill shows \(fade.beginTime - before) s after the attach began, before 1 s")
    }
}
