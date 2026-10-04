import Testing
@testable import CmuxNextUpdater

/// R114: no UI until the update is ready, one click installs, busy agents
/// hold the click, a quit installs unless the user turned that off.
@Suite struct UpdateFlowTests {
    private let prefs = UpdatePreferences.defaults
    private let noon = 12 * 60

    private func ready(_ version: String = "1.0.0-nightly.9") -> UpdateFlow {
        var flow = UpdateFlow()
        _ = flow.handle(.sparkle(.ready(version: version)), preferences: prefs)
        return flow
    }

    @Test func backgroundWorkShowsNothing() {
        var flow = UpdateFlow()
        for phase: UpdateIndicatorPhase in [.checking, .downloading(progress: 0.4), .downloading(progress: nil),
                                            .note(UpdaterStrings.checkFailed, isError: true), .hidden] {
            #expect(flow.handle(.sparkle(phase), preferences: prefs).isEmpty)
            #expect(flow.card(preferences: prefs, minuteOfDay: noon) == nil)
            #expect(!flow.showsSettingsBadge(preferences: prefs))
        }
    }

    @Test func aReadyUpdateIsOneCardAndTheBadge() {
        let flow = ready()
        #expect(flow.card(preferences: prefs, minuteOfDay: noon) == .ready(version: "1.0.0-nightly.9"))
        #expect(flow.showsSettingsBadge(preferences: prefs))
    }

    @Test func oneClickInstallsWhenNothingRuns() {
        var flow = ready()
        #expect(flow.handle(.installRequested, preferences: prefs) == [.install])
    }

    @Test func busyAgentsHoldTheClickUntilTheyFinish() {
        var flow = ready()
        _ = flow.handle(.blockersChanged(UpdateBlockers(busyAgents: 2)), preferences: prefs)
        #expect(flow.handle(.installRequested, preferences: prefs).isEmpty)
        #expect(flow.card(preferences: prefs, minuteOfDay: noon) == .waiting(version: "1.0.0-nightly.9", busyAgents: 2))
        #expect(flow.handle(.blockersChanged(UpdateBlockers(busyAgents: 1)), preferences: prefs).isEmpty)
        #expect(flow.card(preferences: prefs, minuteOfDay: noon) == .waiting(version: "1.0.0-nightly.9", busyAgents: 1))
        #expect(flow.handle(.blockersChanged(.none), preferences: prefs) == [.install])
    }

    @Test func installNowAsksThenInstallsOrKeepsWaiting() {
        var flow = ready()
        _ = flow.handle(.blockersChanged(UpdateBlockers(busyAgents: 1)), preferences: prefs)
        _ = flow.handle(.installRequested, preferences: prefs)
        #expect(flow.handle(.installNowRequested, preferences: prefs) == [.confirmInterrupt(UpdateBlockers(busyAgents: 1))])
        #expect(flow.handle(.interruptDeclined, preferences: prefs).isEmpty)
        #expect(flow.card(preferences: prefs, minuteOfDay: noon) == .waiting(version: "1.0.0-nightly.9", busyAgents: 1))
        _ = flow.handle(.installNowRequested, preferences: prefs)
        #expect(flow.handle(.interruptConfirmed, preferences: prefs) == [.install])
    }

    @Test func laterForgetsTheClickAndKeepsTheUpdateReady() {
        var flow = ready()
        _ = flow.handle(.blockersChanged(UpdateBlockers(busyAgents: 1)), preferences: prefs)
        _ = flow.handle(.installRequested, preferences: prefs)
        #expect(flow.handle(.later, preferences: prefs).isEmpty)
        #expect(flow.card(preferences: prefs, minuteOfDay: noon) == .ready(version: "1.0.0-nightly.9"))
        #expect(flow.handle(.blockersChanged(.none), preferences: prefs).isEmpty)
    }

    @Test func aClickDuringDownloadInstallsOnceStaged() {
        var flow = UpdateFlow()
        _ = flow.handle(.sparkle(.downloading(progress: 0.5)), preferences: prefs)
        #expect(flow.handle(.installRequested, preferences: prefs).isEmpty)
        #expect(flow.handle(.sparkle(.ready(version: "2")), preferences: prefs) == [.install])
    }

    @Test func aClickDuringDownloadWithBusyAgentsWaits() {
        var flow = UpdateFlow()
        _ = flow.handle(.blockersChanged(UpdateBlockers(busyAgents: 3)), preferences: prefs)
        _ = flow.handle(.sparkle(.downloading(progress: nil)), preferences: prefs)
        _ = flow.handle(.installRequested, preferences: prefs)
        #expect(flow.handle(.sparkle(.ready(version: "2")), preferences: prefs).isEmpty)
        #expect(flow.card(preferences: prefs, minuteOfDay: noon) == .waiting(version: "2", busyAgents: 3))
    }

    @Test func aClickWithNothingStagedDoesNothing() {
        var flow = UpdateFlow()
        #expect(flow.handle(.installRequested, preferences: prefs).isEmpty)
        #expect(!flow.installRequested)
    }

    @Test func quitInstallsAStagedUpdateUnlessTurnedOff() {
        var flow = ready()
        #expect(flow.handle(.quitRequested, preferences: prefs) == [.quit(.proceed)])
        var off = ready()
        let noQuitInstall = UpdatePreferences(installOnQuit: false)
        #expect(off.handle(.quitRequested, preferences: noQuitInstall) == [.quit(.cancelPendingInstall)])
        var idle = UpdateFlow()
        #expect(idle.handle(.quitRequested, preferences: noQuitInstall) == [.quit(.proceed)])
    }

    @Test func busyAgentsDoNotBlockAQuit() {
        // Agents run in the daemons, not the app: a quit stops none of them.
        var flow = ready()
        _ = flow.handle(.blockersChanged(UpdateBlockers(busyAgents: 2)), preferences: prefs)
        #expect(flow.handle(.quitRequested, preferences: prefs) == [.quit(.proceed)])
    }

    @Test func installingShowsTheInstallingCardAndEndsTheRequest() {
        var flow = ready()
        _ = flow.handle(.installRequested, preferences: prefs)
        _ = flow.handle(.sparkle(.installing), preferences: prefs)
        #expect(flow.card(preferences: prefs, minuteOfDay: noon) == .installing)
        #expect(!flow.installRequested)
    }

    @Test func aCheckTheUserAskedForShowsItsProgressAndResult() {
        var flow = UpdateFlow()
        _ = flow.handle(.checkRequested, preferences: prefs)
        _ = flow.handle(.sparkle(.checking), preferences: prefs)
        #expect(flow.card(preferences: prefs, minuteOfDay: noon) == .checking)
        _ = flow.handle(.sparkle(.note(UpdaterStrings.upToDate, isError: false)), preferences: prefs)
        #expect(flow.card(preferences: prefs, minuteOfDay: noon) == .note(UpdaterStrings.upToDate, isError: false))
        _ = flow.handle(.noteExpired, preferences: prefs)
        #expect(flow.card(preferences: prefs, minuteOfDay: noon) == nil)
        // The next background check is invisible again.
        _ = flow.handle(.sparkle(.checking), preferences: prefs)
        #expect(flow.card(preferences: prefs, minuteOfDay: noon) == nil)
    }

    @Test func aCheckTheUserAskedForShowsTheDownloadThenTheReadyCard() {
        var flow = UpdateFlow()
        _ = flow.handle(.checkRequested, preferences: prefs)
        _ = flow.handle(.sparkle(.downloading(progress: 0.25)), preferences: prefs)
        #expect(flow.card(preferences: prefs, minuteOfDay: noon) == .downloading(progress: 0.25))
        _ = flow.handle(.sparkle(.ready(version: "3")), preferences: prefs)
        #expect(flow.card(preferences: prefs, minuteOfDay: noon) == .ready(version: "3"))
        #expect(!flow.userAsked)
    }

    @Test func notifyModesAndQuietHoursHideTheCard() {
        let flow = ready()
        let badge = UpdatePreferences(notify: .badge)
        #expect(flow.card(preferences: badge, minuteOfDay: noon) == nil)
        #expect(flow.showsSettingsBadge(preferences: badge))
        let silent = UpdatePreferences(notify: .silent)
        #expect(flow.card(preferences: silent, minuteOfDay: noon) == nil)
        #expect(!flow.showsSettingsBadge(preferences: silent))
        let night = UpdatePreferences(quietHours: UpdateQuietHours(start: 22 * 60, end: 7 * 60))
        #expect(flow.card(preferences: night, minuteOfDay: 23 * 60) == nil)
        #expect(flow.card(preferences: night, minuteOfDay: noon) == .ready(version: "1.0.0-nightly.9"))
    }

    @Test func quietHoursHideNothingTheUserAskedFor() {
        var flow = ready()
        _ = flow.handle(.blockersChanged(UpdateBlockers(busyAgents: 1)), preferences: prefs)
        _ = flow.handle(.installRequested, preferences: prefs)
        let night = UpdatePreferences(notify: .silent, quietHours: UpdateQuietHours(start: 0, end: 1439))
        #expect(flow.card(preferences: night, minuteOfDay: 60) == .waiting(version: "1.0.0-nightly.9", busyAgents: 1))
    }

    @Test func quietHoursWrapPastMidnight() {
        let q = UpdateQuietHours(start: 22 * 60, end: 7 * 60)
        #expect(q.contains(minuteOfDay: 23 * 60))
        #expect(q.contains(minuteOfDay: 3 * 60))
        #expect(!q.contains(minuteOfDay: 7 * 60))
        #expect(!q.contains(minuteOfDay: noon))
        #expect(!UpdateQuietHours(start: 60, end: 60).contains(minuteOfDay: 60))
        #expect(q.minutesToNextBoundary(from: 21 * 60) == 60)
        #expect(q.minutesToNextBoundary(from: 22 * 60) == 9 * 60)
        #expect(q.minutesToNextBoundary(from: 6 * 60 + 59) == 1)
    }

    /// Exhaustive check over short event sequences: the gate never asks to
    /// install while agents are busy unless the user confirmed, and never
    /// installs without a staged update or a user request.
    @Test func noInstallWithoutAStagedUpdateAndARequest() {
        let events: [UpdateFlowEvent] = [
            .sparkle(.downloading(progress: nil)), .sparkle(.ready(version: "9")), .sparkle(.hidden),
            .installRequested, .installNowRequested, .interruptConfirmed, .interruptDeclined, .later,
            .blockersChanged(.none), .blockersChanged(UpdateBlockers(busyAgents: 1)), .checkRequested,
        ]
        func walk(_ flow: UpdateFlow, depth: Int) {
            guard depth > 0 else { return }
            for event in events {
                var next = flow
                let effects = next.handle(event, preferences: prefs)
                if effects.contains(.install) {
                    let staged = flow.phase == .ready(version: "9") || event == .sparkle(.ready(version: "9"))
                    #expect(staged)
                    #expect(flow.installRequested || event == .installRequested)
                    if event == .interruptConfirmed {
                        #expect(flow.confirmationOpen)
                    } else {
                        #expect(next.blockers.isEmpty)
                    }
                }
                walk(next, depth: depth - 1)
            }
        }
        walk(UpdateFlow(), depth: 5)
    }

    /// `updates.downloadAutomatically` off: the found update is a card;
    /// one click downloads, shows the progress, and installs once staged.
    @Test func anUpdateThatWaitsForTheClickDownloadsThenInstalls() {
        var flow = UpdateFlow()
        _ = flow.handle(.sparkle(.available(version: "5")), preferences: prefs)
        #expect(flow.card(preferences: prefs, minuteOfDay: noon) == .available(version: "5"))
        #expect(flow.showsSettingsBadge(preferences: prefs))
        #expect(flow.handle(.installRequested, preferences: prefs) == [.download])
        _ = flow.handle(.sparkle(.downloading(progress: 0.5)), preferences: prefs)
        #expect(flow.card(preferences: prefs, minuteOfDay: noon) == .downloading(progress: 0.5))
        #expect(flow.handle(.sparkle(.ready(version: "5")), preferences: prefs) == [.install])
    }

    @Test func quietHoursAndNotifyModesHideAnAvailableUpdateToo() {
        var flow = UpdateFlow()
        _ = flow.handle(.sparkle(.available(version: "5")), preferences: prefs)
        #expect(flow.card(preferences: UpdatePreferences(notify: .badge), minuteOfDay: noon) == nil)
        let night = UpdatePreferences(quietHours: UpdateQuietHours(start: 0, end: 1439))
        #expect(flow.card(preferences: night, minuteOfDay: noon) == nil)
    }
}
