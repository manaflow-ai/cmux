#if canImport(CmuxMobileLinkFFI)
import CmuxMobileAgentChat
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

@MainActor
@Suite struct UploadActivityRoutingTests {
    @Test func anUploadToOneMacDoesNotExtendAnotherMacsHeldPrompt() async throws {
        let hubA = AcpmuxHub()
        let hubB = AcpmuxHub()
        defer { withExtendedLifetime((hubA, hubB)) {} }
        let linkA = ChatPromptBlipTests.link(.init())
        let linkB = ChatPromptBlipTests.link(.init())
        await hubA.bind(try await linkA.openChannel(service: "acpmux", args: [:]))
        await hubB.bind(try await linkB.openChannel(service: "acpmux", args: [:]))
        var summaryA = ChatPromptBlipTests.summary
        summaryA.macID = "mac-a"
        var summaryB = ChatPromptBlipTests.summary
        summaryB.macID = "mac-b"
        let a = hubA.source(sessionID: "s1", summary: summaryA)
        let b = hubB.source(sessionID: "s1", summary: summaryB)
        let storeA = AgentChatStore(source: a)
        let storeB = AgentChatStore(source: b)
        for _ in 0..<200 { await Task.yield() }
        var now = ContinuousClock.now
        a.now = { now }
        b.now = { now }
        a.heldPromptWindow = .seconds(1)
        b.heldPromptWindow = .seconds(1)
        await hubA.bind(nil)
        await hubB.bind(nil)
        storeA.send(prompt: "a")
        storeB.send(prompt: "b")
        for _ in 0..<2_000 where a.heldPrompts.isEmpty || b.heldPrompts.isEmpty { await Task.yield() }
        #expect(a.heldPrompts.count == 1)
        #expect(b.heldPrompts.count == 1)
        now += .milliseconds(800)
        UploadActivity.advanced(macID: "mac-a")
        now += .milliseconds(400)
        a.flushHeldPrompts()
        b.flushHeldPrompts()
        #expect(a.heldPrompts.count == 1, "the matching Mac made progress within the hold")
        #expect(b.heldPrompts.isEmpty, "another Mac's upload cannot keep this prompt alive")
    }
}
#endif
