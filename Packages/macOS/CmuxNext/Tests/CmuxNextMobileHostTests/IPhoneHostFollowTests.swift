@testable import CmuxNextMobileHost
import CmuxNextWakeups
import Observation
import Testing

/// p06-scheduler-342 (R-obs): the host follows `mobile.allowIPhoneConnections` and the account with one
/// `ServiceObservation` each on the app's scheduler, not a main-inherited ObservationStream task: the value known
/// at the follow applies at once, and a burst of changes applies once, in one posted visible task.
@MainActor
struct IPhoneHostFollowTests {
    @Test func theSettingFollowAppliesNowThenOncePerBurstInAVisibleTask() {
        let turns = IPhoneHostTurns()
        let work = MainWorkScheduler.testing(ledger: WakeupLedger(), performTurn: { turns.queued.append($0) }) { _ in nil }
        let setting = IPhoneHostSetting()
        let host = IPhoneHostService()
        host.follow(allowed: { setting.on }, on: work)
        #expect(!host.allowed)

        setting.on = true
        setting.on = false
        setting.on = true
        #expect(!host.allowed, "the setting applied inside the turn that changed it")
        #expect(work.postedCount(.visible) == 1, "a burst of changes posts one flush, in the visible class")
        turns.run()
        #expect(host.allowed, "the setting never reached the host")

        host.stop()
        setting.on = false
        turns.run()
        #expect(host.allowed, "a stopped host still follows the setting")
    }

    @Test func theAccountFollowAppliesTheAccountKnownAtTheFollow() {
        let turns = IPhoneHostTurns()
        let work = MainWorkScheduler.testing(ledger: WakeupLedger(), performTurn: { turns.queued.append($0) }) { _ in nil }
        let account = IPhoneHostService.Account(userID: "u", teamID: "personal-u", teamName: nil, email: nil)
        let host = IPhoneHostService()
        host.followAccount({ account }, on: work)
        #expect(host.account == account, "the account known at the follow waited for a later turn")
        host.stop()
    }
}

@MainActor @Observable
private final class IPhoneHostSetting {
    var on = false
}

@MainActor
private final class IPhoneHostTurns {
    var queued: [@MainActor () -> Void] = []

    /// Runs the posted run loop turns, those they queue included.
    func run() {
        while !queued.isEmpty { queued.removeFirst()() }
    }
}
