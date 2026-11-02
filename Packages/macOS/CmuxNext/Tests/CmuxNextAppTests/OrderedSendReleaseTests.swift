import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Testing

/// P0 1193 (review of #29919 at a51d0a85518, lead 01:4xZ): an ordered send whose service is released before its turn
/// (a Cloud, SSH or Server session's DaemonService goes away) must not report success with its keys lost. Its ticket
/// closes, and its result is a failure ("not connected"). Before, the queued task held the service weakly and returned
/// success when it was gone, and the ticket stayed open until the action scope's timeout.
@MainActor @Suite struct OrderedSendReleaseTests {
    @Test func anOrderedSendWhoseServiceIsGoneFailsAndClosesItsTicket() async {
        let scope = DaemonCommandScope()
        var tracked: [ActionWork] = []
        var service: DaemonService? = DaemonService(machineID: "cloud:released")
        service?.workTracker = { tracked.append($0) }
        DaemonCommandScope.$current.withValue(scope) {
            service?.sendInOrder("send-key", to: SurfaceID(rawValue: 7)) { _ in }
            service?.sendInOrder("send-key", to: SurfaceID(rawValue: 7)) { _ in }
        }
        // The service goes away before either send's turn (no await between the queueing and the release).
        service = nil
        var results: [ActionWorkFailure?] = []
        for work in tracked { results.append(await work.value) }
        #expect(tracked.count == 2, "the sends were not tracked: \(tracked.count)")
        #expect(results.allSatisfy { $0 != nil }, "a send whose service was gone reported success (its keys lost silently): \(results)")
        #expect(scope.isIdle, "a ticket of a send whose service was gone stayed open")
        #expect(scope.failures.count == 2, "the scope did not record the lost sends as failures: \(scope.failures)")
    }
}
