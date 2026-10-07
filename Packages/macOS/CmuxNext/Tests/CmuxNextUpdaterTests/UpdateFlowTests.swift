import Testing
@testable import CmuxNextUpdater

/// R114 and SIDEBAR-FOOTER-MINIMAL: no UI until the update is staged, then
/// the footer's "Update Ready" pill; one click installs and relaunches at
/// once (the relaunch keeps every terminal and agent, so running agents do
/// not hold it); a quit installs unless the user turned that off.
@Suite struct UpdateFlowTests {
    private let prefs = UpdatePreferences.defaults

    private func ready(_ version: String = "1.0.0-nightly.9") -> UpdateFlow {
        var flow = UpdateFlow()
        _ = flow.handle(.sparkle(.ready(version: version)), preferences: prefs)
        return flow
    }

    private func at(_ phase: UpdateIndicatorPhase) -> UpdateFlow {
        var flow = UpdateFlow()
        _ = flow.handle(.sparkle(phase), preferences: prefs)
        return flow
    }

    /// The update state to footer mapping: nothing while there is no
    /// update, while checking, while downloading, or for a found update
    /// that is not downloaded; the enabled pill once staged; the disabled
    /// pill while it installs.
    @Test func theFooterPillShowsOnlyAStagedUpdate() {
        #expect(UpdateFlow().footerPill(preferences: prefs) == nil)
        #expect(at(.hidden).footerPill(preferences: prefs) == nil)
        #expect(at(.checking).footerPill(preferences: prefs) == nil)
        #expect(at(.downloading(progress: 0.4)).footerPill(preferences: prefs) == nil)
        #expect(at(.downloading(progress: nil)).footerPill(preferences: prefs) == nil)
        #expect(at(.available(version: "5")).footerPill(preferences: prefs) == nil)
        #expect(at(.note(UpdaterStrings.upToDate, isError: false)).footerPill(preferences: prefs) == nil)
        #expect(ready().footerPill(preferences: prefs) == .ready)
        #expect(at(.installing).footerPill(preferences: prefs) == .installing)
    }

    @Test func backgroundWorkShowsNoCard() {
        var flow = UpdateFlow()
        for phase: UpdateIndicatorPhase in [.checking, .downloading(progress: 0.4), .downloading(progress: nil), .available(version: "3"),
                                            .note(UpdaterStrings.checkFailed, isError: true), .ready(version: "3"), .installing, .hidden] {
            _ = flow.handle(.sparkle(phase), preferences: prefs)
            #expect(flow.card == nil)
        }
    }

    @Test func oneClickInstallsWhenStaged() {
        var flow = ready()
        #expect(flow.handle(.installRequested, preferences: prefs) == [.install])
    }

    @Test func aClickDuringDownloadInstallsOnceStaged() {
        var flow = UpdateFlow()
        _ = flow.handle(.sparkle(.downloading(progress: 0.5)), preferences: prefs)
        #expect(flow.handle(.installRequested, preferences: prefs).isEmpty)
        #expect(flow.handle(.sparkle(.ready(version: "2")), preferences: prefs) == [.install])
    }

    @Test func aClickWithNothingStagedDoesNothing() {
        var flow = UpdateFlow()
        #expect(flow.handle(.installRequested, preferences: prefs).isEmpty)
        #expect(!flow.installRequested)
    }

    @Test func aHeldClickDoesNotCarryOverAFailedOrCancelledFlow() {
        var flow = UpdateFlow()
        _ = flow.handle(.sparkle(.downloading(progress: nil)), preferences: prefs)
        _ = flow.handle(.installRequested, preferences: prefs)
        _ = flow.handle(.sparkle(.hidden), preferences: prefs)
        #expect(flow.handle(.sparkle(.ready(version: "2")), preferences: prefs).isEmpty)
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

    @Test func installingEndsTheRequest() {
        var flow = ready()
        _ = flow.handle(.installRequested, preferences: prefs)
        _ = flow.handle(.sparkle(.installing), preferences: prefs)
        #expect(flow.card == nil)
        #expect(!flow.installRequested)
    }

    @Test func aCheckTheUserAskedForShowsItsProgressAndResult() {
        var flow = UpdateFlow()
        _ = flow.handle(.checkRequested, preferences: prefs)
        _ = flow.handle(.sparkle(.checking), preferences: prefs)
        #expect(flow.card == .checking)
        _ = flow.handle(.sparkle(.note(UpdaterStrings.upToDate, isError: false)), preferences: prefs)
        #expect(flow.card == .note(UpdaterStrings.upToDate, isError: false))
        _ = flow.handle(.noteExpired, preferences: prefs)
        #expect(flow.card == nil)
        // The next background check is invisible again.
        _ = flow.handle(.sparkle(.checking), preferences: prefs)
        #expect(flow.card == nil)
    }

    @Test func aCheckTheUserAskedForShowsTheDownloadThenThePill() {
        var flow = UpdateFlow()
        _ = flow.handle(.checkRequested, preferences: prefs)
        _ = flow.handle(.sparkle(.downloading(progress: 0.25)), preferences: prefs)
        #expect(flow.card == .downloading(progress: 0.25))
        _ = flow.handle(.sparkle(.ready(version: "3")), preferences: prefs)
        #expect(flow.card == nil)
        #expect(flow.footerPill(preferences: prefs) == .ready)
        #expect(!flow.userAsked)
    }

    @Test func silentHidesTheStagedPill() {
        let flow = ready()
        #expect(flow.footerPill(preferences: UpdatePreferences(notify: .badge)) == .ready)
        #expect(flow.footerPill(preferences: UpdatePreferences(notify: .silent)) == nil)
    }

    /// Exhaustive check over short event sequences: the gate never installs
    /// without a staged update and a user request.
    @Test func noInstallWithoutAStagedUpdateAndARequest() {
        let events: [UpdateFlowEvent] = [
            .sparkle(.downloading(progress: nil)), .sparkle(.ready(version: "9")), .sparkle(.hidden),
            .installRequested, .checkRequested, .noteExpired, .quitRequested,
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
                }
                walk(next, depth: depth - 1)
            }
        }
        walk(UpdateFlow(), depth: 5)
    }

    /// `updates.downloadAutomatically` off: the found update shows nothing
    /// in the footer; the palette's Install Available Update downloads,
    /// shows the progress, and installs once staged.
    @Test func anUpdateThatWaitsForTheClickDownloadsThenInstalls() {
        var flow = UpdateFlow()
        _ = flow.handle(.sparkle(.available(version: "5")), preferences: prefs)
        #expect(flow.card == nil)
        #expect(flow.footerPill(preferences: prefs) == nil)
        #expect(flow.handle(.installRequested, preferences: prefs) == [.download])
        _ = flow.handle(.sparkle(.downloading(progress: 0.5)), preferences: prefs)
        #expect(flow.card == .downloading(progress: 0.5))
        #expect(flow.handle(.sparkle(.ready(version: "5")), preferences: prefs) == [.install])
    }
}
