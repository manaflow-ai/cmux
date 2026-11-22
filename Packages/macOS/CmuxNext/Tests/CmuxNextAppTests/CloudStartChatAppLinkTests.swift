import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextDaemonService
import CmuxNextWakeups
import Foundation
import Testing

/// A composer Cloud start (`cloud.startChat`) and Move to Cloud on the Cloud app server's link,
/// the link every DEV and tagged build uses. The app link's carrier socket serves each connection
/// as its own dial of the machine's daemon (`first-party-apps/cloud/server/src/link/carrier.rs`,
/// up to 64 at once), so the CLIs' copy takes a connection of its own beside the app's, as
/// `cmux link machine update` already does (``CloudLinkSession/currentSocket``). Neither the start
/// nor the machine's connect refuses that link any more (HQ capture run 41392333978: the start card
/// failed at "Set up a Cloud machine" with `unavailable` and no machine was made).
@Suite
@MainActor
struct CloudStartChatAppLinkTests {
    /// A machine on the app link goes on to its own state checks: a deleting one is refused as
    /// deleting, never as a link that can't take a chat.
    @Test func aMachineOnTheAppLinkIsNotRefusedForItsLink() async {
        let session = CloudMachineSession(machine: CloudMachine(id: "vm-app", status: .deleting, displayName: "App VM"),
                                          appLink: CloudLinkSession(key: CloudLinkKey(machine: "vm-app"), resolver: UnusedLinkResolver()),
                                          localIdentity: { nil }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        defer { session.disconnect() }
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: "tab-1"), origin: .user)
        do {
            _ = try await CloudMove.connected(session, invocation)
            Issue.record("a deleting machine connected")
        } catch let failure as CloudMove.Failure {
            Issue.record("refused for its link: \(failure.message)")
        } catch let failure as ActionFailure {
            #expect(failure.message == CloudStrings.machineChanging(.deleting))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

/// Move to Cloud's owner answer on the app link (router review BLOCK at 51832a5): an owned
/// machine's connect answer is `owner`, sent with no legacy link PID; any other is `none`.
@Suite
@MainActor
struct CloudMoveAppLinkOwnerTests {
    @Test func anOwnedAppLinkMachineMovesAsOwnerWithNoLinkPID() async throws {
        for (owns, kind) in [(true, "owner"), (false, "none")] {
            let link = CloudLinkSession(key: CloudLinkKey(machine: "vm-app"), resolver: AnsweringLinkResolver(owns: owns))
            let session = CloudMachineSession(machine: CloudMachine(id: "vm-app", displayName: "App VM"), appLink: link,
                                              localIdentity: { nil }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            defer { session.disconnect() }
            try await link.connect(origin: .user)
            let answer = await CloudMove.ownerAnswer(session)
            #expect(answer.vmKind == kind)
            #expect(answer.toPID == nil)
        }
    }

    @Test func anAppLinkThatHasNotConnectedIsNotAnOwner() async {
        let session = CloudMachineSession(machine: CloudMachine(id: "vm-app", displayName: "App VM"),
                                          appLink: CloudLinkSession(key: CloudLinkKey(machine: "vm-app"), resolver: UnusedLinkResolver()),
                                          localIdentity: { nil }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        defer { session.disconnect() }
        let answer = await CloudMove.ownerAnswer(session)
        #expect(answer.vmKind == "none" && answer.toPID == nil)
    }
}

/// The app server's `cloud.machine.connect` answering a socket and its owner answer.
private struct AnsweringLinkResolver: CloudLinkResolver {
    let owns: Bool

    func open(_ key: CloudLinkKey, intent: String, origin: CloudLinkOrigin) async throws -> CloudLinkSocket {
        CloudLinkSocket(key: key, path: "/tmp/cn-unused.sock", generation: 1, callerOwnsVM: owns)
    }

    func close(_ key: CloudLinkKey) async {}
}

/// A link resolver the test never reaches: the deleting machine is refused before it connects.
private struct UnusedLinkResolver: CloudLinkResolver {
    func open(_ key: CloudLinkKey, intent: String, origin: CloudLinkOrigin) async throws -> CloudLinkSocket {
        throw CloudLinkError.unsupported
    }

    func close(_ key: CloudLinkKey) async {}
}
