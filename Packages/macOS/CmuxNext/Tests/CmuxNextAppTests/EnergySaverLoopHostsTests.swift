import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextDesign
@testable import CmuxNextHome
@testable import CmuxNextSidebar
@testable import MessagesLabHome
@testable import MessagesLabSidebar
import Testing

/// Energy Saver flips at runtime (a plug, Low Power Mode, the battery under 20 %), far more often
/// than Reduce Motion. Every host that caches a loop decision follows it at once, both ways, with
/// no new content: the notice card's sweep, Home's vendored typing loops and the agent page's
/// status loops (plans/cmux-next/motion-DESIGN.md).
@MainActor @Suite(.serialized) struct EnergySaverLoopHostsTests {
    /// Runs `body` with Reduce Motion pinned off and the saver off, then puts both back.
    private func withSaverOff(_ body: () throws -> Void) rethrows {
        let design = DesignSettings.shared
        let old = design.energySaver
        Motion.reduceMotionOverride = false
        design.energySaver = false
        defer {
            design.energySaver = old
            Motion.reduceMotionOverride = nil
        }
        try body()
    }

    /// An unmeasured notice sweeps; the saver stills the sweep and turning it off brings the sweep
    /// back (the bar row was hidden meanwhile), with no new notice.
    @Test func theNoticeCardsSweepFollowsTheSaver() {
        let design = DesignSettings()
        design.animationsEnabled = true
        design.disabledAnimationCategories = []
        design.animationSpeed = .fast
        withSaverOff {
            let checking = SidebarNoticeCard(id: "update", title: "Checking for Updates…", progress: .indeterminate)
            let card = SidebarNoticeCardView(motionPolicy: { Motion.basePolicy(of: design).for(.overlays) }, motionSignals: design.signals)
            card.frame = NSRect(x: 0, y: 0, width: 240, height: SidebarNoticeCardView.height(for: checking))
            card.configure(checking)
            card.layoutSubtreeIfNeeded()
            #expect(card.progressShown == .sweeping, "an unmeasured notice does not sweep: \(card.progressShown)")
            design.energySaver = true
            card.layoutSubtreeIfNeeded()
            #expect(card.progressShown == .still, "the sweep runs on under the saver: \(card.progressShown)")
            design.energySaver = false
            card.layoutSubtreeIfNeeded()
            #expect(card.progressShown == .sweeping, "the sweep does not come back after the saver: \(card.progressShown)")
        }
    }

    /// Home's list bubble and transcript typing row hold still under the saver, a running pulse
    /// stops when it turns on and starts again when it turns off; Reduce Motion stays off throughout.
    @Test func homesTypingLoopsFollowTheSaver() {
        withSaverOff {
            let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 600)) // installs HomeReduceMotion
            guard Motion.sidebar.animatesLoops, Motion.home.animatesLoops else { return } // this run turned Home's motion off
            #expect(!CmuxSidebarView.hostStillsLoops && !MessagesLabHomeView.hostStillsLoops)
            home.list.wantsLayer = true
            let bubble = SidebarTypingLayer()
            home.list.layer?.addSublayer(bubble)
            bubble.animate()
            #expect(ReduceMotionLoopTests.loops(under: bubble) != [], "the bubble should pulse with the saver off")

            DesignSettings.shared.energySaver = true
            #expect(CmuxSidebarView.hostStillsLoops && MessagesLabHomeView.hostStillsLoops)
            #expect(!CmuxSidebarView.reducesMotion, "the saver is not Reduce Motion")
            #expect(ReduceMotionLoopTests.loops(under: bubble) == [], "the bubble keeps pulsing under the saver")
            let cell = RowCell(frame: CGRect(x: 0, y: 0, width: 400, height: 40))
            cell.startTypingDots(begin: CACurrentMediaTime())
            cell.startTypingBreath(insert: CACurrentMediaTime())
            let typing = cell.dots + cell.typingDiscs + [cell.typingContainer, cell.typingClip]
            #expect(typing.flatMap { ReduceMotionLoopTests.loops(under: $0) } == [], "the typing row loops under the saver")

            DesignSettings.shared.energySaver = false
            #expect(ReduceMotionLoopTests.loops(under: bubble) != [], "the bubble does not pulse again after the saver")
            cell.applyReduceMotion()
            #expect(typing.flatMap { ReduceMotionLoopTests.loops(under: $0) } != [], "the typing row stays still after the saver")
        }
    }

    /// The agent page's status loops are static under the saver, as under Reduce Motion.
    @Test func theAgentPagesStatusLoopsFollowTheSaver() {
        let design = DesignSettings.shared
        let before = design.statusIndicator
        defer { design.statusIndicator = before }
        design.statusIndicator.animation = .animated
        func look(_ motion: MotionPolicy) -> String? { AgentPaneTheme.values(.unresolved, motion: motion)["statusIndicators"] as? String }
        var motion = MotionPolicy(speed: .fast, reduceMotion: false, category: .web)
        #expect(look(motion) == "animated")
        motion.energySaver = true
        #expect(look(motion) == "static")
    }
}
