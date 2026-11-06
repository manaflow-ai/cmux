import CoreGraphics
import Foundation
import Testing
@testable import CmuxMobileChief

/// Chief info's Computer card (https://github.com/manaflow-ai/cmux/issues/31488): the Cloud
/// Chief's own computer, shown once the Chief has used one, refreshed while it runs and the card
/// is on screen, and never read while it sleeps.
@MainActor @Suite(.serialized) struct ChiefComputerTests {
    @Test func theCardShowsOnceTheChiefUsedAComputer() {
        #expect(ChiefComputer.shown(nil, name: "Ada") == nil)
        #expect(ChiefComputer.shown(.init(used: false, machineID: nil, state: nil), name: "Ada") == nil)
        let live = ChiefComputer.shown(.init(used: true, machineID: "vm", state: "running"), name: "Ada")
        #expect(live?.title == "Ada’s Computer")
        #expect(live?.state == .live)
        #expect(ChiefComputer.shown(.init(used: true, machineID: "vm", state: "suspended"), name: "Ada")?.state == .asleep)
        #expect(ChiefComputer.shown(.init(used: true, machineID: nil, state: nil), name: "Ada")?.state == .unavailable)
    }

    @Test func theRouteAnswerParses() {
        let body = Data(#"{"ok":true,"value":{"used":true,"computer":{"id":"vm-9","state":"paused","name":null}}}"#.utf8)
        #expect(ChiefComputerStatus(json: body) == .init(used: true, machineID: "vm-9", state: "paused"))
        #expect(ChiefComputerStatus(json: Data(#"{"ok":false}"#.utf8)) == nil)
    }

    @Test func aRunningComputerRefreshesUntilTheCardGoes() async {
        let source = Source(.init(used: true, machineID: "vm", state: "running"))
        let computer = rig(source)
        let follow = Task { await computer.follow(chief: "agent_x", name: "Ada") }
        await until { source.screens >= 3 && computer.frame != nil }
        #expect(computer.shown?.state == .live)
        follow.cancel()
        await follow.value
        let screens = source.screens
        await settle()
        #expect(source.screens == screens)
    }

    @Test func anAsleepComputerIsNeverRead() async {
        let source = Source(.init(used: true, machineID: "vm", state: "suspended"))
        let computer = rig(source)
        let follow = Task { await computer.follow(chief: "agent_x", name: "Ada") }
        await until { computer.shown?.state == .asleep && source.statuses >= 3 }
        #expect(source.screens == 0)
        #expect(computer.frame == nil)
        follow.cancel()
        await follow.value
    }

    @Test func noCloudChiefHidesTheCard() async {
        let source = Source(.init(used: true, machineID: "vm", state: "running"))
        let computer = rig(source)
        await computer.follow(chief: nil, name: "Ada")
        #expect(computer.shown == nil)
        #expect(source.statuses == 0)
    }

    // MARK: Rig

    final class Source: ChiefComputerSource {
        var status: ChiefComputerStatus?
        var statuses = 0
        var screens = 0
        let image: CGImage? = CGContext(data: nil, width: 16, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()

        init(_ status: ChiefComputerStatus?) { self.status = status }

        func computerStatus(chief: String) async -> ChiefComputerStatus? {
            statuses += 1
            return status
        }

        func computerScreen(chief: String) async -> CGImage? {
            screens += 1
            return image
        }
    }

    private func rig(_ source: Source) -> ChiefComputer {
        let computer = ChiefComputer()
        computer.source = source
        // Every wait is one turn: the test drives the timing.
        computer.pause = { _ in await Task.yield() }
        return computer
    }

    private func until(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<2_000 where !condition() { await Task.yield() }
        #expect(condition())
    }

    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }
}
