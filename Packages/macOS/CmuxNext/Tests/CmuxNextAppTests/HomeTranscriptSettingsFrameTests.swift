import AppKit
import CmuxHomeCore
import CmuxNextDesign
import CmuxNextWakeups
@testable import CmuxNextHome
import Foundation
import Testing

/// The Home transcript follows its live settings through one FrameObservation (plans/cmux-next/
/// chrome-parity/p04-input.md, task 028), not one main-actor task per setting and change: a burst
/// of switches applies once after its turn, and a transcript out of any window, or parked hidden
/// in one, applies nothing until a person can see it, then reads once.
@MainActor @Suite(.serialized) struct HomeTranscriptSettingsFrameTests {
    private func transcript(_ work: MainWorkScheduler) -> HomeNativeTranscriptView {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(HomeTunables.all)
        let home = HomeStore(source: MockHomeSource(options: .immediate))
        return HomeNativeTranscriptView(store: home, conversation: ConversationID("conv_settings"), me: ParticipantID("user_me"),
                                        mainWork: work)
    }

    private func window(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 600)
        window.contentView?.addSubview(view)
        return window
    }

    private func applies(_ work: MainWorkScheduler) throws -> ObservationLedger.Entry {
        try #require(work.observations.snapshot(matching: "home.transcript.settings").first)
    }

    @Test func aBurstOfSwitchesAppliesOnceAfterItsTurn() throws {
        defer { TunableStore.shared.set(HomeTunables.firstRunHero.key, nil) }
        let work = linklessMainWork()
        let view = transcript(work)
        let window = window(view)
        defer { window.close() }
        #expect(view.firstRun.showsHero)
        for index in 0..<21 { TunableStore.shared.set(HomeTunables.firstRunHero.key, .bool(index % 2 == 1)) }
        #expect(view.firstRun.showsHero, "the hero switch applied inside the switches' own turn")
        #expect(runMainLoop { !view.firstRun.showsHero })
        #expect(try applies(work).applies == 1, "21 switches applied more than once")
        view.stop()
    }

    @Test func aTranscriptOutOfAnyWindowAppliesNothingUntilItIsInOne() throws {
        defer { TunableStore.shared.set(HomeTunables.firstRunHero.key, nil) }
        let work = linklessMainWork()
        let view = transcript(work)
        TunableStore.shared.set(HomeTunables.firstRunHero.key, .bool(false))
        for _ in 0..<5 { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
        #expect(view.firstRun.showsHero, "a transcript in no window applied a setting")
        #expect(try applies(work).evaluations == 0, "a transcript in no window read its settings")
        let window = window(view)
        defer { window.close() }
        #expect(!view.firstRun.showsHero, "the transcript did not read its settings once on joining the window")
        #expect(try applies(work).showRereads == 1)
        view.stop()
    }

    /// A parked tab stays in its window with `isHidden` (`PaneContentView+Parking`): its transcript
    /// is hidden through an ancestor, so it applies nothing until the tab shows again.
    @Test func aParkedTranscriptAppliesNothingUntilItShowsAgain() throws {
        defer { TunableStore.shared.set(HomeTunables.firstRunHero.key, nil) }
        let work = linklessMainWork()
        let view = transcript(work)
        let tab = NSView()
        let window = window(tab)
        defer { window.close() }
        view.frame = tab.bounds
        tab.addSubview(view)
        #expect(view.firstRun.showsHero)
        #expect(try applies(work).showRereads == 1, "the transcript did not read its settings on joining the window")
        tab.isHidden = true
        TunableStore.shared.set(HomeTunables.firstRunHero.key, .bool(false))
        for _ in 0..<5 { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
        #expect(view.firstRun.showsHero, "a parked transcript applied a setting")
        #expect(try applies(work).evaluations == 0, "a parked transcript read its settings")
        tab.isHidden = false
        #expect(!view.firstRun.showsHero, "the transcript did not read its settings once when its tab showed again")
        #expect(try applies(work).showRereads == 2)
        view.stop()
    }
}
