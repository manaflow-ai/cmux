import CmuxNextHomeModel
import Testing

/// `debug.home` read `home_workspace.step: "waiting for the chief owner cmux-chief-…"` while
/// `chief_owner.connected` was true (air-blue, DEV build of #44303): the Chief tab's wait wrote
/// a fixed sentence into the step the dock's setup shares, and nothing replaced it. The Chief's
/// step is now its own (`chief_step`) and the wait is read against the owner's live state.
@Suite struct HomeChiefTabStepTests {
    @Test func theWaitFollowsTheOwnersLiveState() {
        let step = HomeChiefTabStep.waitingForOwner
        #expect(step.text(session: "cmux-chief-a", connected: false, servesLocal: false)
            == "waiting for the chief owner cmux-chief-a to connect")
        let connected = step.text(session: "cmux-chief-a", connected: true, servesLocal: false)
        #expect(!connected.hasPrefix("waiting for the chief owner"), "a connected owner is never reported as not there")
        #expect(connected.contains("local conversations"), "it names what the owner still lacks")
        let serving = step.text(session: "cmux-chief-a", connected: true, servesLocal: true)
        #expect(!serving.contains("waiting"), "an owner that connected and serves is not waited on")
    }

    @Test func aReachedStepIsReportedAsIs() {
        #expect(HomeChiefTabStep.reached("chief tab present").text(session: "s", connected: false, servesLocal: false) == "chief tab present")
        #expect(HomeChiefTabStep.notStarted.text(session: "s", connected: true, servesLocal: true) == "not started")
    }
}
