import AppKit
import CmuxHomeCore
@testable import CmuxNextDesign
@testable import CmuxNextHome
import CmuxNextWakeups
@testable import MessagesLabHome
@testable import MessagesLabSidebar
import Testing

/// Home's vendored loops (MessagesLab's caret blink, typing dots and breath, and the list's typing
/// pulse) run through ``HomeLoopProbe``, a ``LoopHost`` under their window's visibility node
/// (p14-energy-115): an occluded or miniaturized window keeps none of them in the render server, and
/// showing it puts each back.
@MainActor @Suite(.serialized) struct HomeLoopVisibilityTests {
    /// A window whose visibility the test sets, as an occlusion or miniaturize notice would.
    @MainActor final class FakeWindow {
        var state: Visibility = .visible
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        private(set) var source: WindowVisibilitySource!

        init() {
            window.isReleasedWhenClosed = false
            window.contentView = NSView(frame: window.contentLayoutRect)
            source = WindowVisibilitySource.of(window, name: "homeLoopTestWindow") { [unowned self] _ in self.state }
        }

        func set(_ state: Visibility) {
            self.state = state
            source.refresh()
        }
    }

    private func withMotionOn(_ body: () throws -> Void) rethrows {
        let design = DesignSettings.shared
        let saver = design.energySaver
        Motion.reduceMotionOverride = false
        design.energySaver = false
        defer {
            design.energySaver = saver
            Motion.reduceMotionOverride = nil
        }
        try body()
    }

    /// The transcript's typing row and caret: on while the window shows, off while it is occluded or
    /// miniaturized, back when it shows again.
    @Test func homesTranscriptLoopsComeOffWhileItsWindowIsOccluded() throws {
        try withMotionOn {
            HomeReduceMotion.install() // the vendored views read cmux's Reduce Motion and loop gate
            guard Motion.home.animatesLoops, !MessagesLabHomeView.stillsLoops else { return } // this run turned Home's motion off
            let fake = FakeWindow()
            let probe = HomeLoopProbe("test.home.transcript.loops")
            let content = try #require(fake.window.contentView)
            content.addSubview(probe)
            let cell = RowCell(frame: CGRect(x: 0, y: 0, width: 400, height: 40))
            cell.loops = LabLoops(probe)
            cell.startTypingDots(begin: CACurrentMediaTime())
            cell.startTypingBreath(insert: CACurrentMediaTime())
            let field = FieldTextView(usingTextLayoutManager: true)
            field.loops = LabLoops(probe)
            field.startBlink()
            let typing = cell.dots + cell.typingDiscs + [cell.typingContainer, cell.typingClip]
            func running() -> [String] { typing.flatMap { ReduceMotionLoopTests.loops(under: $0) } }
            #expect(!running().isEmpty, "the typing row does not loop in a shown window")
            #expect(field.caretLayer.animation(forKey: "blink") != nil, "the caret does not blink in a shown window")

            for state in [Visibility.occluded, .hidden] {
                fake.set(state)
                #expect(running().isEmpty, "a \(state) window's typing row loops: \(running())")
                #expect(field.caretLayer.animation(forKey: "blink") == nil, "a \(state) window's caret blinks")
                #expect(probe.runningCount == 0)
                fake.set(.visible)
                #expect(!running().isEmpty, "the typing row does not loop again after the window was \(state)")
                #expect(field.caretLayer.animation(forKey: "blink") != nil, "the caret does not blink again after \(state)")
            }

            // A breath that ended while the window was occluded does not come back with it.
            fake.set(.occluded)
            cell.stopTypingBreath()
            fake.set(.visible)
            let breath = [cell.typingContainer, cell.typingClip].flatMap { ReduceMotionLoopTests.loops(under: $0) }
            #expect(breath.isEmpty, "a stopped breath came back with the window: \(breath)")
        }
    }

    /// The conversation list's typing bubble pulses through the list's probe, which Home installs.
    @Test func homesListPulseComesOffWhileItsWindowIsOccluded() throws {
        try withMotionOn {
            let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 600))
            guard Motion.sidebar.animatesLoops else { return } // this run turned the sidebar's motion off
            let probe = try #require(home.list.loops as? HomeLoopProbe, "Home's list has no window-following loop host")
            #expect(home.list.subviews.contains(probe))
            let fake = FakeWindow()
            try #require(fake.window.contentView).addSubview(home)
            home.list.wantsLayer = true
            let bubble = SidebarTypingLayer()
            bubble.loops = home.list.loops
            home.list.layer?.addSublayer(bubble)
            bubble.animate()
            #expect(ReduceMotionLoopTests.loops(under: bubble) != [], "the bubble does not pulse in a shown window")
            fake.set(.occluded)
            #expect(ReduceMotionLoopTests.loops(under: bubble) == [], "an occluded window's bubble pulses")
            fake.set(.visible)
            #expect(ReduceMotionLoopTests.loops(under: bubble) != [], "the bubble does not pulse again when the window shows")
            home.list.isHidden = true
            #expect(ReduceMotionLoopTests.loops(under: bubble) == [], "a hidden list's bubble pulses")
        }
    }
}
