import AppKit
@testable import CmuxNextHomeEngine
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The Chief Settings card's Computer section (cmux issue 31488): the Chief's own computer, shown
/// only with a paid plan once the Chief has set one up; while it runs its screen refreshes for as
/// long as the card is open, and asleep it is never read.
@MainActor @Suite(.serialized) struct HomeChiefComputerTests {
    @Test func theSectionNeedsAPaidPlanAndAChiefThatUsedAComputer() {
        let running = HomeChiefComputer.Status(used: true, computer: ("vm-1", "running"))
        #expect(HomeChiefComputer(status: running, paid: false, chief: "Ada") == nil)
        #expect(HomeChiefComputer(status: .init(used: false, computer: nil), paid: true, chief: "Ada") == nil)
        #expect(HomeChiefComputer(status: nil, paid: true, chief: "Ada") == nil)
        #expect(HomeChiefComputer(status: running, paid: true, chief: "Ada")
            == HomeChiefComputer(machineID: "vm-1", title: "Ada’s screen", state: .live))
        // Used once, gone now: the section stays, unavailable.
        #expect(HomeChiefComputer(status: .init(used: true, computer: nil), paid: true, chief: "Ada")?.state == .unavailable)
    }

    @Test func freestyleStatesMapToTheSectionsStates() {
        #expect(HomeChiefComputer.state(of: "running") == .live)
        for asleep in ["paused", "suspended", "stopped"] { #expect(HomeChiefComputer.state(of: asleep) == .asleep) }
        #expect(HomeChiefComputer.state(of: "starting") == .waking)
        #expect(HomeChiefComputer.state(of: "failed") == .unavailable)
    }

    @Test func theRouteAnswerParses() throws {
        let body = Data(#"{"ok":true,"value":{"used":true,"computer":{"id":"vm-9","state":"paused","name":null},"screen":{"width":1280,"height":800}}}"#.utf8)
        #expect(HomeChiefComputer.Status(json: body) == .init(used: true, computer: ("vm-9", "paused")))
        #expect(HomeChiefComputer.Status(json: Data(#"{"ok":true,"value":{"used":false,"computer":null}}"#.utf8)) == .init(used: false, computer: nil))
        #expect(HomeChiefComputer.Status(json: Data(#"{"ok":false,"error":{"code":"not_found"}}"#.utf8)) == nil)
    }

    @Test func aRunningComputerRefreshesOnlyWhileTheCardIsOpen() async throws {
        let rig = Rig(status: .init(used: true, computer: ("vm", "running")))
        #expect(rig.section.isHidden)
        rig.section.open()
        await until { rig.section.frames >= 1 }
        try await rig.tick(HomeChiefComputerSection.frameInterval)
        await until { rig.section.frames >= 2 }
        try await rig.tick(HomeChiefComputerSection.frameInterval)
        await until { rig.section.frames >= 3 }
        #expect(!rig.section.isHidden)
        #expect(rig.section.shown?.title == "Ada’s screen")
        #expect(rig.section.screen.layer?.contents != nil)
        rig.section.close()
        let shots = rig.feed.screens
        rig.clock.advance(by: .seconds(60))
        await settle()
        #expect(rig.feed.screens == shots)
        #expect(rig.section.screen.layer?.contents == nil)
    }

    @Test func anAsleepComputerIsNeverRead() async throws {
        let rig = Rig(status: .init(used: true, computer: ("vm", "suspended")))
        rig.section.open()
        await until { rig.section.shown?.state == .asleep }
        try await rig.tick(HomeChiefComputerSection.statusInterval)
        await until { rig.feed.statuses >= 2 }
        await settle()
        #expect(rig.feed.screens == 0)
        #expect(!rig.section.isHidden)
        // It wakes: the next status read starts the frames.
        rig.feed.status = .init(used: true, computer: ("vm", "running"))
        try await rig.tick(HomeChiefComputerSection.statusInterval)
        await until { rig.section.frames >= 1 }
        rig.section.close()
    }

    @Test func aFailedStatusReadKeepsTheSectionAsUnavailable() async throws {
        let rig = Rig(status: .init(used: true, computer: ("vm", "running")))
        rig.section.open()
        await until { rig.section.frames >= 1 }
        rig.feed.status = nil
        // The state is read again once a status interval of frames has passed.
        for _ in 0..<9 { try await rig.tick(HomeChiefComputerSection.frameInterval) }
        await until { rig.feed.statuses >= 2 }
        #expect(!rig.section.isHidden)
        #expect(rig.section.shown?.state == .unavailable)
        rig.section.close()
    }

    @Test func noPaidPlanHidesTheSectionAndReadsNoScreen() async {
        let rig = Rig(status: .init(used: true, computer: ("vm", "running")), paid: false)
        rig.section.open()
        await until { rig.feed.statuses >= 1 }
        await settle()
        #expect(rig.section.isHidden)
        #expect(rig.feed.screens == 0)
        rig.section.close()
    }

    @Test func showingAndHidingResizesTheCard() async throws {
        let rig = Rig(status: .init(used: true, computer: ("vm", "paused")))
        var resizes = 0
        rig.section.onResize = { resizes += 1 }
        rig.section.open()
        await until { rig.section.shown != nil }
        #expect(resizes == 1)
        rig.feed.status = .init(used: false, computer: nil)
        try await rig.tick(HomeChiefComputerSection.statusInterval)
        await until { rig.section.shown == nil }
        #expect(resizes == 2)
        #expect(rig.section.isHidden)
        rig.section.close()
    }

    // MARK: Rig

    @MainActor final class Feed {
        var status: HomeChiefComputer.Status?
        var statuses = 0
        var screens = 0
        let image: CGImage?

        init(status: HomeChiefComputer.Status?) {
            self.status = status
            let context = CGContext(data: nil, width: 16, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            image = context?.makeImage()
        }
    }

    @MainActor struct Rig {
        let feed: Feed
        let clock = ManualClock()
        let section = HomeChiefComputerSection()

        init(status: HomeChiefComputer.Status?, paid: Bool = true) {
            let feed = Feed(status: status)
            self.feed = feed
            section.source = .init(paid: { paid }, chief: { "Ada" },
                                   status: { feed.statuses += 1; return feed.status },
                                   screen: { feed.screens += 1; return feed.image },
                                   clock: clock)
        }

        /// The next read is due: waits for the section's timer, then moves the clock by `interval`.
        func tick(_ interval: Duration) async throws {
            try await clock.waitForSleeper()
            clock.advance(by: interval)
        }
    }

    /// Lets the section's loop catch up: a bounded number of turns, no clock.
    private func until(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<2_000 where !condition() { await Task.yield() }
        #expect(condition())
    }

    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }
}
