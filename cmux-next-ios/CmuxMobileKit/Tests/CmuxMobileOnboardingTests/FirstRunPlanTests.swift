#if os(iOS)
import Testing
@testable import CmuxMobileOnboarding

/// The first-run plan: "Here's how cmux works" opens setup and "Start your
/// first agent" ends it whenever setup asks anything; a returning account with
/// everything settled sees no setup.
@Suite struct FirstRunPlanTests {
    @Test func aNewAccountGetsTheWholeFlow() {
        #expect(SetupFlow.plan(teamCount: 0, macOnline: false, asksNotifications: true)
            == [.intro, .team, .pairMac, .notifications, .firstChat])
    }

    @Test func onlyWhatIsUnsettledIsAsked() {
        #expect(SetupFlow.plan(teamCount: 1, macOnline: false, asksNotifications: false) == [.intro, .pairMac, .firstChat])
        #expect(SetupFlow.plan(teamCount: 2, macOnline: true, asksNotifications: false) == [.intro, .team, .firstChat])
        #expect(SetupFlow.plan(teamCount: 1, macOnline: true, asksNotifications: true) == [.intro, .notifications, .firstChat])
    }

    @Test func nothingToAskMeansNoSetup() {
        #expect(SetupFlow.plan(teamCount: 1, macOnline: true, asksNotifications: false).isEmpty)
    }

    @Test func theIntroLeadsToTheFirstPlannedPage() {
        let plan = SetupFlow.plan(teamCount: 1, macOnline: true, asksNotifications: true)
        #expect(SetupFlow.step(after: .intro, in: plan) == .notifications)
        #expect(SetupFlow.step(after: .notifications, in: plan) == .firstChat)
        #expect(SetupFlow.step(after: .firstChat, in: plan) == nil)
    }

    @Test func aCapturedPageHasThePagesBeforeItOnTheStack() {
        let all = SetupFlow.order.filter { $0 != .createTeam }
        #expect(SetupFlow.path(to: .intro, in: all) == [])
        #expect(SetupFlow.path(to: .firstChat, in: all) == [.team, .pairMac, .notifications, .firstChat])
        #expect(SetupFlow.path(to: .pairMac, in: [.intro, .pairMac, .firstChat]) == [.pairMac])
        #expect(SetupFlow.path(to: .team, in: [.intro, .pairMac]) == [])
    }

    @Test func everyStepNameRoundTrips() {
        for step in SetupFlow.Step.allCases { #expect(SetupFlow.Step(rawValue: step.rawValue) == step) }
    }
}

@Suite struct FirstChatSuggestionTests {
    @Test func fourDistinctStarters() {
        let starters = FirstChatSuggestion.starters
        #expect(starters.count == 4)
        #expect(Set(starters.map(\.id)).count == 4)
        #expect(starters.allSatisfy { !$0.prompt.isEmpty && !$0.title.isEmpty && !$0.symbol.isEmpty })
    }

    @Test func aTypedTaskIsTrimmedAndBlankSendsNothing() {
        #expect(FirstChatSuggestion.typedPrompt("  fix the build \n") == "fix the build")
        #expect(FirstChatSuggestion.typedPrompt(" \n\t ") == nil)
        #expect(FirstChatSuggestion.typedPrompt("") == nil)
    }

    @Test func thePageSaysWhereTheTaskRuns() {
        let online = FirstChatDestination(onlineMac: "Aziz's MacBook Pro")
        #expect(online.isOnline)
        #expect(online.status == "Aziz's MacBook Pro")
        #expect(online.subtitle.contains("Aziz's MacBook Pro"))
        let waiting = FirstChatDestination(onlineMac: nil)
        #expect(!waiting.isOnline)
        #expect(waiting.status == "Waiting for your Mac")
        #expect(FirstChatDestination(onlineMac: "") == waiting)
    }
}
#endif
