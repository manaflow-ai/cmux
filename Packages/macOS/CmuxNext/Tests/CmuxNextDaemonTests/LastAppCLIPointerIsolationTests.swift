@testable import CmuxNextDaemon
import Testing

/// Only a user's launch claims the account's `cmux` shim: an agent launch (no-activate) and a bench
/// launch that may activate (`CMUX_NEXT_ISOLATED_LAUNCH=1`, idle-budget's shipping mode)
/// never do.
@Suite struct LastAppCLIPointerIsolationTests {
    @Test func onlyAUsersLaunchPublishesTheCLIPointer() {
        #expect(LastAppCLIPointer.shouldPublish(environment: [:]))
        #expect(LastAppCLIPointer.shouldPublish(environment: ["CMUX_NEXT_NO_ACTIVATE": "1"]) == false)
        #expect(LastAppCLIPointer.shouldPublish(environment: ["CMUX_NEXT_ISOLATED_LAUNCH": "1"]) == false)
    }
}
