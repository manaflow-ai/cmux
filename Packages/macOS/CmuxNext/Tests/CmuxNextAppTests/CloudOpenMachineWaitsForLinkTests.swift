import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import Foundation
import Testing

/// Leo, 2026-11-01, on a new Cloud workspace: "when i tried to click it this happens", a
/// "Cloud Action Failed: The Cloud machine is not connected yet" sheet. Open Machine attached
/// (which starts the link) and then read the machine's workspaces at once, so a running machine
/// whose link was still coming up refused. A person's open now waits, bounded, for that link.
@MainActor @Suite(.serialized)
struct CloudOpenMachineWaitsForLinkTests {
    @Observable @MainActor final class Link {
        var connected = false
        var failure: String?
    }

    @Test(.timeLimit(.minutes(1)))
    func aLinkThatComesUpAfterTheClickOpens() async {
        let link = Link()
        let wait = Task { @MainActor in
            await CloudWait.linkFailure(within: .seconds(20), connected: { link.connected }, failure: { link.failure }, deadline: "not connected")
        }
        await Task.yield()
        link.connected = true
        #expect(await wait.value == nil, "the open refused before the link it started came up")
    }

    /// The last link's failure still shows when the click lands; the click's connect clears it.
    /// It must not end the wait at once, only a failure of the new connect does.
    @Test(.timeLimit(.minutes(1)))
    func theLastLinksFailureDoesNotEndTheWait() async {
        let link = Link()
        link.failure = "link ended"
        let wait = Task { @MainActor in
            await CloudWait.linkFailure(within: .seconds(20), connected: { link.connected }, failure: { link.failure }, deadline: "not connected")
        }
        await Task.yield()
        link.failure = nil
        await Task.yield()
        link.connected = true
        #expect(await wait.value == nil, "a failure from before the click ended the wait")
    }

    @Test(.timeLimit(.minutes(1)))
    func aFailureOfTheNewConnectSaysWhy() async {
        let link = Link()
        let wait = Task { @MainActor in
            await CloudWait.linkFailure(within: .seconds(20), connected: { link.connected }, failure: { link.failure }, deadline: "not connected")
        }
        await Task.yield()
        link.failure = "the machine refused the link"
        #expect(await wait.value == "the machine refused the link")
    }

    @Test(.timeLimit(.minutes(1)))
    func aLinkThatNeverComesEndsAtTheDeadline() async {
        let link = Link()
        let reason = await CloudWait.linkFailure(within: .milliseconds(50), connected: { link.connected }, failure: { link.failure }, deadline: "not connected")
        #expect(reason == "not connected")
    }

    /// A CLI or agent run keeps its answer: Open Machine's attach returns at once, as before.
    @Test(.timeLimit(.minutes(1)))
    func aCLIOpenDoesNotWaitForTheLink() async throws {
        let services = MachineIconTests.services()
        let session = MachineIconTests.cloudMachine(services, id: "vm-open-\(UUID().uuidString.prefix(8))")
        session.machine.status = .running
        session.refresher = { _ in }
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .machine, id: session.machineID), arguments: [:], origin: .cli)
        let started = ContinuousClock.now
        try await CloudHandlers.attached(session, invocation, within: .seconds(30), waitsForLink: true)
        #expect(ContinuousClock.now - started < .seconds(10))
        session.disconnect()
    }

    /// A person's open of a running machine with no link up waits for it (here it never comes:
    /// the deadline says why) instead of refusing the moment the click lands.
    @Test(.timeLimit(.minutes(1)))
    func aPersonsOpenWaitsForTheLink() async {
        let services = MachineIconTests.services()
        let session = MachineIconTests.cloudMachine(services, id: "vm-open-\(UUID().uuidString.prefix(8))")
        session.machine.status = .running
        session.refresher = { _ in }
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .machine, id: session.machineID), arguments: [:], origin: .user)
        let started = ContinuousClock.now
        await #expect(throws: ActionFailure.self) {
            try await CloudHandlers.attached(session, invocation, within: .milliseconds(300), waitsForLink: true)
        }
        let waited = ContinuousClock.now - started
        #expect(waited >= .milliseconds(300) || session.stage.failure != nil, "the open refused at once with no link failure")
        session.disconnect()
    }
}
