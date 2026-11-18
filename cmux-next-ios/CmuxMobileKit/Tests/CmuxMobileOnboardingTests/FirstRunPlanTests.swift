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

    @Test func aBuildThatSellsPlansShowsThemBeforeTheFirstAgentButNeverAlone() {
        #expect(SetupFlow.plan(teamCount: 0, macOnline: false, asksNotifications: true, sellsPlans: true)
            == [.intro, .team, .pairMac, .notifications, .plan, .firstChat])
        #expect(SetupFlow.plan(teamCount: 1, macOnline: true, asksNotifications: false, sellsPlans: true).isEmpty)
        let plan = SetupFlow.plan(teamCount: 1, macOnline: true, asksNotifications: true, sellsPlans: true)
        #expect(SetupFlow.step(after: .notifications, in: plan) == .plan)
        #expect(SetupFlow.step(after: .plan, in: plan) == .firstChat)
    }

    @Test func theNotificationsPageVersionComesFromItsLaunchArgument() {
        #expect(NotificationsPrimer.choice(in: ["app", "-cmux-mobile-notifications-primer", "preview"]) == .preview)
        #expect(NotificationsPrimer.choice(in: ["app", "-cmux-mobile-notifications-primer", "actions"]) == .actions)
        #expect(NotificationsPrimer.choice(in: ["app", "-cmux-mobile-notifications-primer", "nope"]) == nil)
        #expect(NotificationsPrimer.choice(in: ["app", "-cmux-mobile-notifications-primer"]) == nil)
        #expect(NotificationsPrimer.allCases.count == 3)
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
        #expect(SetupFlow.path(to: .firstChat, in: all) == [.team, .pairMac, .notifications, .plan, .firstChat])
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
        #expect(!online.offersConnect)
        #expect(waiting.offersConnect)
    }

    @Test func anAccountWithNoMacIsToldSoAndOfferedTheWayToConnectOne() {
        let none = FirstChatDestination(onlineMac: nil, accountHasMac: false)
        #expect(none.kind == .noMac)
        #expect(none.status == "No Mac connected")
        #expect(none.subtitle.contains("connect your Mac"))
        #expect(none.offersConnect)
        // An unknown Mac count never claims there is none; an online Mac wins.
        #expect(FirstChatDestination(onlineMac: nil, accountHasMac: nil).kind == .waiting)
        #expect(FirstChatDestination(onlineMac: nil, accountHasMac: true).kind == .waiting)
        #expect(FirstChatDestination(onlineMac: "Mac mini", accountHasMac: false).isOnline)
    }
}
#endif
