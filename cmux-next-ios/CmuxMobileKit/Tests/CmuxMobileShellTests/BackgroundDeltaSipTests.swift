#if os(iOS)
import Foundation
import Testing
@testable import CmuxMobileShell
#if canImport(CmuxMobileLinkFFI)
@testable import CmuxMobileLive
#endif

@MainActor @Suite(.timeLimit(.minutes(1)))
struct BackgroundDeltaSipTests {
    /// The sip's end and the system's expiration both finish a run; the task completes once.
    @Test func aRunCompletesItsTaskOnce() {
        var completions: [Bool] = []
        let run = SipRun { completions.append($0) }
        run.finish(true)
        run.finish(false)
        #expect(completions == [true])
    }

    @Test func expirationFirstWins() {
        var completions: [Bool] = []
        let run = SipRun { completions.append($0) }
        run.finish(false)
        run.finish(true)
        #expect(completions == [false])
    }

    #if canImport(CmuxMobileLinkFFI)
    /// Off by default: no wake is asked for until a catch-up setting is on.
    @Test func aWakeIsAskedForOnlyWithACatchUpSettingOn() throws {
        let name = "BackgroundDeltaSipTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(!LiveCoordinator.backgroundSipEnabled(defaults))
        defaults.set(true, forKey: MacCatchUps.enabledKey)
        #expect(LiveCoordinator.backgroundSipEnabled(defaults))
        defaults.set(false, forKey: MacCatchUps.enabledKey)
        defaults.set(true, forKey: RelayCatchUp.enabledKey)
        #expect(LiveCoordinator.backgroundSipEnabled(defaults))
    }
    #endif
}
#endif
