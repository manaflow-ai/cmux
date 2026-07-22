import Foundation
import Testing
import UserNotifications
@testable import CmuxNotifications

@MainActor
private final class FakeNotificationCenter: UserNotificationCenterConfiguring {
    private(set) var categories: Set<UNNotificationCategory> = []
    private(set) var delegate: (any UNUserNotificationCenterDelegate)?

    func currentNotificationCategories() async -> Set<UNNotificationCategory> {
        categories
    }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        self.categories = categories
    }

    func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?) {
        self.delegate = delegate
    }
}

@MainActor
private final class FakeTerminalNavigation: NotificationDeliveryTerminalNavigating {
    struct OpenCall: Equatable {
        let tabId: UUID
        let surfaceId: UUID?
        let notificationId: UUID?
    }

    var openSucceeds = true
    var performSucceeds = true
    private(set) var opens: [OpenCall] = []
    private(set) var storedOpens: [(
        id: UUID,
        fallbackTabId: UUID,
        fallbackSurfaceId: UUID?,
        fallbackRetargetsToLiveSurfaceOwner: Bool
    )] = []
    private(set) var performedClickActions: [NotificationNavClickAction] = []
    private(set) var markedReadIds: [UUID] = []

    func open(tabId: UUID, surfaceId: UUID?, notificationId: UUID?) -> Bool {
        opens.append(OpenCall(tabId: tabId, surfaceId: surfaceId, notificationId: notificationId))
        return openSucceeds
    }

    func openNotification(
        id: UUID,
        fallbackTabId: UUID,
        fallbackSurfaceId: UUID?,
        fallbackRetargetsToLiveSurfaceOwner: Bool
    ) -> Bool {
        storedOpens.append((id, fallbackTabId, fallbackSurfaceId, fallbackRetargetsToLiveSurfaceOwner))
        return openSucceeds
    }

    func performClickAction(_ action: NotificationNavClickAction) -> Bool {
        performedClickActions.append(action)
        return performSucceeds
    }

    func markNotificationRead(id: UUID) {
        markedReadIds.append(id)
    }
}

@MainActor
private final class FakeTerminalReplying: NotificationTerminalReplying {
    struct Reply: Equatable {
        let text: String
        let tabId: UUID
        let surfaceId: UUID?
        let retargetsToLiveSurfaceOwner: Bool
    }

    var succeeds = true
    private(set) var replies: [Reply] = []

    func sendReply(
        text: String,
        tabId: UUID,
        surfaceId: UUID?,
        retargetsToLiveSurfaceOwner: Bool
    ) -> Bool {
        replies.append(.init(
            text: text,
            tabId: tabId,
            surfaceId: surfaceId,
            retargetsToLiveSurfaceOwner: retargetsToLiveSurfaceOwner
        ))
        return succeeds
    }
}

@MainActor
private final class FakeFeedReplying: NotificationFeedReplying {
    struct Reply: Equatable {
        let requestId: String
        let decision: NotificationFeedDecision
    }

    var capabilitiesByRequestId: [String: NotificationFeedPermissionCapabilities] = [:]
    private(set) var replies: [Reply] = []

    func deliverReply(requestId: String, decision: NotificationFeedDecision) {
        replies.append(Reply(requestId: requestId, decision: decision))
    }

    func permissionCapabilities(requestId: String) -> NotificationFeedPermissionCapabilities? {
        capabilitiesByRequestId[requestId]
    }
}

@MainActor
private final class FakeApplicationActivation: NotificationApplicationActivating {
    private(set) var activationCount = 0

    func activateApplication() {
        activationCount += 1
    }
}

private final class DummyNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {}

@Suite(.serialized)
@MainActor
struct NotificationDeliveryCoordinatorTests {
    @Test("configure installs terminal and Feed categories and delegate")
    func configureInstallsCategoriesAndDelegate() async throws {
        let center = FakeNotificationCenter()
        let delegate = DummyNotificationDelegate()
        let coordinator = makeCoordinator(center: center)

        coordinator.configureUserNotifications(delegate: delegate)
        await Task.yield()

        let categories = categoriesByIdentifier(center.categories)
        #expect((center.delegate as AnyObject?) === delegate)
        #expect(Set(categories.keys) == [
            "terminal.category",
            "terminal.textReply",
            "CMUXFeedPermission",
            "CMUXFeedPermissionDeny",
            "CMUXFeedPermissionOnce",
            "CMUXFeedPermissionAlways",
            "CMUXFeedPermissionAll",
            "CMUXFeedPermissionOnceAlways",
            "CMUXFeedPermissionOnceAll",
            "CMUXFeedPermissionAlwaysAll",
            "CMUXFeedPermissionOnceAlwaysAll",
            "CMUXFeedExitPlan",
            "CMUXFeedQuestion",
        ])
        let terminalCategory = try #require(categories["terminal.category"])
        #expect(terminalCategory.actions.map(\.identifier) == ["terminal.show"])
        #expect(terminalCategory.actions.map(\.title) == ["Show"])
        #expect(terminalCategory.options.contains(.customDismissAction))

        let textReplyCategory = try #require(categories["terminal.textReply"])
        #expect(textReplyCategory.actions.map(\.identifier) == ["terminal.reply", "terminal.show"])
        #expect(textReplyCategory.actions.first is UNTextInputNotificationAction)
        #expect(textReplyCategory.options.contains(.customDismissAction))

        let fullPermission = try #require(categories["CMUXFeedPermissionOnceAlwaysAll"])
        #expect(fullPermission.actions.map(\.identifier) == [
            "feed.permission.once",
            "feed.permission.always",
            "feed.permission.all",
            "feed.permission.deny",
        ])
        #expect(fullPermission.actions.last?.options.contains(.destructive) == true)

        let denyOnlyPermission = try #require(categories["CMUXFeedPermissionDeny"])
        #expect(denyOnlyPermission.actions.map(\.identifier) == ["feed.permission.deny"])

        let exitPlan = try #require(categories["CMUXFeedExitPlan"])
        #expect(exitPlan.actions.map(\.identifier) == [
            "feed.exit_plan.ultraplan",
            "feed.exit_plan.manual",
            "feed.exit_plan.autoAccept",
            "feed.exit_plan.revise",
        ])
        #expect(exitPlan.actions.last is UNTextInputNotificationAction)

        let question = try #require(categories["CMUXFeedQuestion"])
        #expect(question.actions.map(\.identifier) == ["feed.question.open"])
        #expect(question.actions.first?.options.contains(.foreground) == true)
    }

    @Test("presentation options include sound only when the notification has sound")
    func presentationOptions() {
        let coordinator = makeCoordinator()

        let quiet = coordinator.presentationOptions(notificationHasSound: false)
        #expect(quiet.contains(.banner))
        #expect(quiet.contains(.list))
        #expect(!quiet.contains(.sound))

        let audible = coordinator.presentationOptions(notificationHasSound: true)
        #expect(audible.contains(.banner))
        #expect(audible.contains(.list))
        #expect(audible.contains(.sound))
    }

    @Test("Feed permission always falls back to once when always is unsupported")
    func feedPermissionAlwaysFallsBackToOnce() {
        let feed = FakeFeedReplying()
        feed.capabilitiesByRequestId["req-1"] = NotificationFeedPermissionCapabilities(
            supportsOnce: true,
            supportsAlways: false,
            supportsAll: false
        )
        let coordinator = makeCoordinator(feedReplying: feed)

        coordinator.handle(NotificationDeliveryResponse(
            categoryIdentifier: "CMUXFeedPermissionOnceAlways",
            actionIdentifier: "feed.permission.always",
            requestIdentifier: "feed.req-1",
            userInfo: ["requestId": "req-1"]
        ))

        #expect(feed.replies == [.init(requestId: "req-1", decision: .permission(.once))])
    }

    @Test("Feed permission action is consumed without reply when requested mode is unsupported")
    func feedPermissionUnsupportedModeDoesNotReply() {
        let feed = FakeFeedReplying()
        feed.capabilitiesByRequestId["req-1"] = NotificationFeedPermissionCapabilities(
            supportsOnce: true,
            supportsAlways: true,
            supportsAll: false
        )
        let coordinator = makeCoordinator(feedReplying: feed)

        coordinator.handle(NotificationDeliveryResponse(
            categoryIdentifier: "CMUXFeedPermissionAll",
            actionIdentifier: "feed.permission.all",
            requestIdentifier: "feed.req-1",
            userInfo: ["requestId": "req-1"]
        ))

        #expect(feed.replies.isEmpty)
    }

    @Test("Feed response without request id is consumed before terminal routing")
    func feedMissingRequestIdIsConsumed() {
        let terminal = FakeTerminalNavigation()
        let feed = FakeFeedReplying()
        let coordinator = makeCoordinator(terminalNavigation: terminal, feedReplying: feed)

        coordinator.handle(NotificationDeliveryResponse(
            categoryIdentifier: "CMUXFeedQuestion",
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            requestIdentifier: "feed.missing",
            userInfo: ["tabId": UUID().uuidString]
        ))

        #expect(feed.replies.isEmpty)
        #expect(terminal.opens.isEmpty)
    }

    @Test("Feed question default response activates the app")
    func feedQuestionDefaultActivatesApp() {
        let activation = FakeApplicationActivation()
        let coordinator = makeCoordinator(applicationActivation: activation)

        coordinator.handle(NotificationDeliveryResponse(
            categoryIdentifier: "CMUXFeedQuestion",
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            requestIdentifier: "feed.req-2",
            userInfo: ["requestId": "req-2"]
        ))

        #expect(activation.activationCount == 1)
    }

    @Test("exit-plan revise sends manual mode with trimmed feedback")
    func exitPlanReviseSendsFeedback() {
        let feed = FakeFeedReplying()
        let coordinator = makeCoordinator(feedReplying: feed)

        coordinator.handle(NotificationDeliveryResponse(
            categoryIdentifier: "CMUXFeedExitPlan",
            actionIdentifier: "feed.exit_plan.revise",
            requestIdentifier: "feed.req-revise",
            userInfo: ["requestId": "req-revise"],
            userText: "  revise the tests  "
        ))

        #expect(feed.replies == [
            .init(requestId: "req-revise", decision: .exitPlan(.manual, feedback: "revise the tests")),
        ])
    }

    @Test("dynamic question option sends the matching option id")
    func dynamicQuestionOptionSendsSelection() {
        let feed = FakeFeedReplying()
        let coordinator = makeCoordinator(feedReplying: feed)

        coordinator.handle(NotificationDeliveryResponse(
            categoryIdentifier: "CMUXFeedQuestion.req-question",
            actionIdentifier: "feed.question.option.1",
            requestIdentifier: "feed.req-question",
            userInfo: [
                "requestId": "req-question",
                "questionOptionIds": ["one", "two", "three"],
            ]
        ))

        #expect(feed.replies == [
            .init(requestId: "req-question", decision: .question(selections: ["two"])),
        ])
    }

    @Test("dynamic question other sends raw user text")
    func dynamicQuestionOtherSendsRawText() {
        let feed = FakeFeedReplying()
        let coordinator = makeCoordinator(feedReplying: feed)

        coordinator.handle(NotificationDeliveryResponse(
            categoryIdentifier: "CMUXFeedQuestion.req-question",
            actionIdentifier: "feed.question.other",
            requestIdentifier: "feed.req-question",
            userInfo: ["requestId": "req-question"],
            userText: "  keep these spaces  "
        ))

        #expect(feed.replies == [
            .init(requestId: "req-question", decision: .question(selections: ["  keep these spaces  "])),
        ])
    }

    @Test("malformed dynamic question action activates the app without replying")
    func malformedDynamicQuestionActivatesApp() {
        let feed = FakeFeedReplying()
        let activation = FakeApplicationActivation()
        let coordinator = makeCoordinator(
            feedReplying: feed,
            applicationActivation: activation
        )

        coordinator.handle(NotificationDeliveryResponse(
            categoryIdentifier: "CMUXFeedQuestion.req-question",
            actionIdentifier: "feed.question.option.9",
            requestIdentifier: "feed.req-question",
            userInfo: [
                "requestId": "req-question",
                "questionOptionIds": ["one", "two"],
            ]
        ))

        #expect(feed.replies.isEmpty)
        #expect(activation.activationCount == 1)
    }

    @Test("terminal text reply sends to exact surface and marks read")
    func terminalTextReplySendsAndMarksRead() {
        let terminal = FakeTerminalNavigation()
        let replying = FakeTerminalReplying()
        let tabId = UUID()
        let surfaceId = UUID()
        let notificationId = UUID()
        let coordinator = makeCoordinator(terminalNavigation: terminal, terminalReplying: replying)

        coordinator.handle(NotificationDeliveryResponse(
            categoryIdentifier: "terminal.textReply",
            actionIdentifier: "terminal.reply",
            requestIdentifier: notificationId.uuidString,
            userInfo: [
                "tabId": tabId.uuidString,
                "surfaceId": surfaceId.uuidString,
                "retargetsToLiveSurfaceOwner": false,
            ],
            userText: "  continue  "
        ))

        #expect(replying.replies == [.init(
            text: "continue",
            tabId: tabId,
            surfaceId: surfaceId,
            retargetsToLiveSurfaceOwner: false
        )])
        #expect(terminal.markedReadIds == [notificationId])
        #expect(terminal.storedOpens.isEmpty)
    }

    @Test("empty terminal text reply falls back to opening")
    func emptyTerminalTextReplyOpens() {
        let terminal = FakeTerminalNavigation()
        let replying = FakeTerminalReplying()
        let tabId = UUID()
        let notificationId = UUID()
        let coordinator = makeCoordinator(terminalNavigation: terminal, terminalReplying: replying)

        coordinator.handle(NotificationDeliveryResponse(
            categoryIdentifier: "terminal.textReply",
            actionIdentifier: "terminal.reply",
            requestIdentifier: notificationId.uuidString,
            userInfo: ["tabId": tabId.uuidString],
            userText: " \n "
        ))

        #expect(replying.replies.isEmpty)
        #expect(terminal.storedOpens.count == 1)
    }

    @Test("reply shape wire and agent category mappings fail closed")
    func replyShapeMappings() {
        #expect(TerminalNotificationReplyShape(wire: nil) == .none)
        #expect(TerminalNotificationReplyShape(wire: "unknown") == .none)
        #expect(TerminalNotificationReplyShape(wire: "text") == .text)
        #expect(TerminalNotificationReplyShape.forAgentCategory(wire: "turn-complete") == .text)
        #expect(TerminalNotificationReplyShape.forAgentCategory(wire: "idle-reminder") == .text)
        #expect(TerminalNotificationReplyShape.forAgentCategory(wire: "needs-permission") == .none)
        #expect(TerminalNotificationReplyShape.forAgentCategory(wire: "other") == .none)
        #expect(TerminalNotificationReplyShape.forAgentCategory(wire: nil) == .none)
    }

    @Test("terminal default response with click action performs and marks read")
    func terminalDefaultClickActionPerformsAndMarksRead() {
        let terminal = FakeTerminalNavigation()
        let notificationId = UUID()
        let tabId = UUID()
        let coordinator = makeCoordinator(terminalNavigation: terminal)

        coordinator.handle(NotificationDeliveryResponse(
            categoryIdentifier: "terminal.category",
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            requestIdentifier: notificationId.uuidString,
            userInfo: [
                "tabId": tabId.uuidString,
                "cmuxClickAction": "revealInFinder",
                "cmuxRevealInFinderPath": "/tmp/report.txt",
            ]
        ))

        #expect(terminal.performedClickActions == [.revealInFinder(path: "/tmp/report.txt")])
        #expect(terminal.markedReadIds == [notificationId])
        #expect(terminal.opens.isEmpty)
    }

    @Test("terminal default response opens stored notification using notificationId fallback")
    func terminalDefaultOpensStoredNotification() {
        let terminal = FakeTerminalNavigation()
        let tabId = UUID()
        let surfaceId = UUID()
        let notificationId = UUID()
        let coordinator = makeCoordinator(terminalNavigation: terminal)

        coordinator.handle(NotificationDeliveryResponse(
            categoryIdentifier: "terminal.category",
            actionIdentifier: "terminal.show",
            requestIdentifier: "not-a-uuid",
            userInfo: [
                "tabId": tabId.uuidString,
                "surfaceId": surfaceId.uuidString,
                "notificationId": notificationId.uuidString,
                "retargetsToLiveSurfaceOwner": false,
            ]
        ))

        #expect(terminal.storedOpens.count == 1)
        #expect(terminal.storedOpens.first?.id == notificationId)
        #expect(terminal.storedOpens.first?.fallbackTabId == tabId)
        #expect(terminal.storedOpens.first?.fallbackSurfaceId == surfaceId)
        #expect(terminal.storedOpens.first?.fallbackRetargetsToLiveSurfaceOwner == false)
        #expect(terminal.opens.isEmpty)
        #expect(terminal.markedReadIds.isEmpty)

        coordinator.handle(NotificationDeliveryResponse(
            categoryIdentifier: "terminal.category",
            actionIdentifier: "terminal.show",
            requestIdentifier: UUID().uuidString,
            userInfo: [
                "tabId": tabId.uuidString,
                "surfaceId": surfaceId.uuidString,
            ]
        ))

        #expect(terminal.storedOpens.last?.fallbackRetargetsToLiveSurfaceOwner == true)
    }

    @Test("terminal default response without notification id opens raw tab and surface")
    func terminalDefaultWithoutNotificationIdOpensTarget() {
        let terminal = FakeTerminalNavigation()
        let tabId = UUID()
        let surfaceId = UUID()
        let coordinator = makeCoordinator(terminalNavigation: terminal)

        coordinator.handle(NotificationDeliveryResponse(
            categoryIdentifier: "terminal.category",
            actionIdentifier: "terminal.show",
            requestIdentifier: "not-a-uuid",
            userInfo: [
                "tabId": tabId.uuidString,
                "surfaceId": surfaceId.uuidString,
            ]
        ))

        #expect(terminal.opens == [.init(tabId: tabId, surfaceId: surfaceId, notificationId: nil)])
        #expect(terminal.storedOpens.isEmpty)
        #expect(terminal.markedReadIds.isEmpty)
    }

    @Test("terminal dismiss marks notification read using request identifier")
    func terminalDismissMarksRead() {
        let terminal = FakeTerminalNavigation()
        let tabId = UUID()
        let notificationId = UUID()
        let coordinator = makeCoordinator(terminalNavigation: terminal)

        coordinator.handle(NotificationDeliveryResponse(
            categoryIdentifier: "terminal.category",
            actionIdentifier: UNNotificationDismissActionIdentifier,
            requestIdentifier: notificationId.uuidString,
            userInfo: ["tabId": tabId.uuidString]
        ))

        #expect(terminal.markedReadIds == [notificationId])
        #expect(terminal.opens.isEmpty)
    }

    @Test("terminal dismiss marks notification read without requiring tab id")
    func terminalDismissMarksReadWithoutTabId() {
        let terminal = FakeTerminalNavigation()
        let notificationId = UUID()
        let coordinator = makeCoordinator(terminalNavigation: terminal)

        coordinator.handle(NotificationDeliveryResponse(
            categoryIdentifier: "terminal.category",
            actionIdentifier: UNNotificationDismissActionIdentifier,
            requestIdentifier: notificationId.uuidString,
            userInfo: [:]
        ))

        #expect(terminal.markedReadIds == [notificationId])
        #expect(terminal.opens.isEmpty)
    }

    private func makeCoordinator(
        center: FakeNotificationCenter = FakeNotificationCenter(),
        terminalNavigation: FakeTerminalNavigation = FakeTerminalNavigation(),
        terminalReplying: FakeTerminalReplying = FakeTerminalReplying(),
        feedReplying: FakeFeedReplying = FakeFeedReplying(),
        applicationActivation: FakeApplicationActivation = FakeApplicationActivation()
    ) -> NotificationDeliveryCoordinator {
        NotificationDeliveryCoordinator(
            center: center,
            terminalNavigation: terminalNavigation,
            terminalReplying: terminalReplying,
            feedReplying: feedReplying,
            applicationActivation: applicationActivation,
            terminalIdentifiers: TerminalNotificationDeliveryIdentifiers(
                categoryIdentifier: "terminal.category",
                textReplyCategoryIdentifier: "terminal.textReply",
                showActionIdentifier: "terminal.show",
                replyActionIdentifier: "terminal.reply",
                retargetsToLiveSurfaceOwnerUserInfoKey: "retargetsToLiveSurfaceOwner"
            ),
            actionTitles: NotificationDeliveryActionTitles(
                show: "Show",
                reply: "Reply",
                replySend: "Send",
                replyPlaceholder: "Message the agent…",
                feedPermissionAllowOnce: "Allow Once",
                feedPermissionAlways: "Always",
                feedPermissionAll: "All tools",
                feedPermissionDeny: "Deny",
                feedExitPlanUltraplan: "Ultraplan",
                feedExitPlanManual: "Manual",
                feedExitPlanAutoAccept: "Auto",
                feedExitPlanRevise: "Revise…",
                feedQuestionReply: "Reply",
                feedQuestionOther: "Other…"
            )
        )
    }

    private func categoriesByIdentifier(
        _ categories: Set<UNNotificationCategory>
    ) -> [String: UNNotificationCategory] {
        Dictionary(uniqueKeysWithValues: categories.map { ($0.identifier, $0) })
    }
}
