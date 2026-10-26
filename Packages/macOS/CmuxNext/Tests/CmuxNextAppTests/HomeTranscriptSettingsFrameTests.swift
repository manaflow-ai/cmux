import AppKit
import CmuxHomeCore
import CmuxNextDesign
import CmuxNextWakeups
@testable import CmuxNextHome
import Foundation
import Testing

/// The Home transcript follows its live settings through one FrameObservation (plans/cmux-next/
/// chrome-parity/p04-input.md, task 028), not one main-actor task per setting and change: a burst
/// of switches applies once after its turn, and a transcript out of any window applies nothing
/// until it is in one, then reads once.
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
}
