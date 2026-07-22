import AppKit
import CMUXAgentLaunch
import CmuxNotifications
import Foundation

#if DEBUG
@MainActor
final class NotificationDebugEmitter {
    static let shared = NotificationDebugEmitter()

    static let kinds = [
        "turn-complete",
        "idle",
        "needs-permission",
        "error",
        "cli",
        "cli-reply",
        "osc",
        "hook-failed",
        "feed-permission",
        "feed-exit-plan",
        "feed-question",
        "feed-question-4opts",
        "feed-question-multiselect",
        "feed-question-multi",
        "feed-question-many-options",
    ]

    /// Debug-mode switch that forces Feed notifications through the inactive-app banner path.
    var isModeEnabled = false {
        didSet {
            if isModeEnabled {
                FeedCoordinatorTestHooks.isAppActiveOverride = { false }
            } else {
                FeedCoordinatorTestHooks.isAppActiveOverride = nil
            }
        }
    }

    private let desktopIngress = GhosttyDesktopNotificationIngress()

    private init() {}

    @discardableResult
    func emit(kind: String, forceBanner: Bool) -> Bool {
        emit(kind: kind, forceBanner: forceBanner, target: focusedTarget())
    }

    @discardableResult
    func emit(kind: String, forceBanner: Bool, target: NotificationDebugTarget?) -> Bool {
        if forceBanner {
            isModeEnabled = true
        }
        if kind == "all" {
            var emittedAll = true
            for childKind in Self.kinds {
                if !emit(kind: childKind, forceBanner: false, target: target) {
                    emittedAll = false
                }
            }
            return emittedAll
        }
        guard Self.kinds.contains(kind) else { return false }

        if kind.hasPrefix("feed-") {
            return emitFeed(kind: kind, target: target)
        }
        guard let target, let surfaceId = target.surfaceId else { return false }

        let title = String(
            localized: "debug.notification.synthetic.title",
            defaultValue: "Notification Debug"
        )
        let bodyFormat = String(
            localized: "debug.notification.synthetic.body",
            defaultValue: "Synthetic %@ notification"
        )
        let displayName = displayName(for: kind)
        let body = String(format: bodyFormat, displayName)
        switch kind {
        case "turn-complete":
            return emitAgent(
                target: target,
                surfaceId: surfaceId,
                title: title,
                subtitle: displayName,
                body: body,
                category: .turnComplete
            )
        case "idle":
            return emitAgent(
                target: target,
                surfaceId: surfaceId,
                title: title,
                subtitle: displayName,
                body: body,
                category: .idleReminder
            )
        case "needs-permission":
            return emitAgent(
                target: target,
                surfaceId: surfaceId,
                title: title,
                subtitle: displayName,
                body: body,
                category: .needsPermission
            )
        case "error":
            return emitAgent(
                target: target,
                surfaceId: surfaceId,
                title: title,
                subtitle: displayName,
                body: body,
                category: .other
            )
        case "cli", "cli-reply":
            TerminalController.shared.deliverNotificationSynchronously(
                tabId: target.workspaceId,
                surfaceId: surfaceId,
                title: title,
                subtitle: displayName,
                body: body,
                replyShape: kind == "cli-reply" ? .text : .none
            )
            return true
        case "osc":
            return desktopIngress.submit(GhosttyDesktopNotificationRequest(
                tabId: target.workspaceId,
                surfaceId: surfaceId,
                hookDirectory: nil,
                title: title,
                body: body
            ))
        case "hook-failed":
            TerminalNotificationStore.shared.reportNotificationHookFailure(
                TerminalNotificationPolicyFailure(
                    hookId: "debug.synthetic",
                    sourcePath: nil,
                    message: body
                )
            )
            return true
        default:
            return false
        }
    }

    private func emitAgent(
        target: NotificationDebugTarget,
        surfaceId: UUID,
        title: String,
        subtitle: String,
        body: String,
        category: AgentNotifyCategory
    ) -> Bool {
        AgentNotificationDelivery().enqueue(
            workspaceID: target.workspaceId,
            surfaceID: surfaceId,
            title: title,
            subtitle: subtitle,
            body: body,
            category: category,
            pending: false,
            coalesces: false
        )
    }

    private func emitFeed(kind: String, target: NotificationDebugTarget?) -> Bool {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let requestId = "debug-\(suffix)"
        let event = feedEvent(kind: kind, requestId: requestId, target: target)
        guard let event else { return false }

        Thread.detachNewThread {
            _ = FeedCoordinator.shared.ingestBlocking(event: event, waitTimeout: 300)
        }
        return true
    }

    private func feedEvent(
        kind: String,
        requestId: String,
        target: NotificationDebugTarget?
    ) -> WorkstreamEvent? {
        let common = (
            workspaceId: target?.workspaceId.uuidString,
            surfaceId: target?.surfaceId?.uuidString
        )
        switch kind {
        case "feed-permission":
            return WorkstreamEvent(
                sessionId: requestId,
                hookEventName: .permissionRequest,
                source: "claude",
                workspaceId: common.workspaceId,
                surfaceId: common.surfaceId,
                toolName: "Bash",
                toolInputJSON: #"{"command":"echo notification-debug","pattern":"echo *"}"#,
                requestId: requestId
            )
        case "feed-exit-plan":
            return WorkstreamEvent(
                sessionId: requestId,
                hookEventName: .exitPlanMode,
                source: "claude",
                workspaceId: common.workspaceId,
                surfaceId: common.surfaceId,
                toolInputJSON: String(
                    localized: "debug.notification.synthetic.plan",
                    defaultValue: "Inspect the notification and verify the actions."
                ),
                requestId: requestId
            )
        case "feed-question", "feed-question-4opts", "feed-question-multiselect",
             "feed-question-multi", "feed-question-many-options":
            return WorkstreamEvent(
                sessionId: requestId,
                hookEventName: .askUserQuestion,
                source: "claude",
                workspaceId: common.workspaceId,
                surfaceId: common.surfaceId,
                toolName: "AskUserQuestion",
                toolInputJSON: questionJSON(kind: kind),
                requestId: requestId
            )
        default:
            return nil
        }
    }

    private func questionJSON(kind: String) -> String {
        let optionCount = kind == "feed-question-4opts" ? 4
            : (kind == "feed-question-many-options" ? 6 : 3)
        let multiSelect = kind == "feed-question-multiselect"
        let questionCount = kind == "feed-question-multi" ? 2 : 1
        let questions: [[String: Any]] = (0..<questionCount).map { questionIndex in
            [
                "id": "q\(questionIndex)",
                "question": String(
                    localized: "debug.notification.synthetic.question",
                    defaultValue: "Choose a notification debug answer"
                ),
                "multiSelect": multiSelect,
                "options": (0..<optionCount).map { optionIndex in
                    [
                        "id": "option-\(optionIndex + 1)",
                        "label": String(
                            format: String(
                                localized: "debug.notification.synthetic.option",
                                defaultValue: "Option %d"
                            ),
                            optionIndex + 1
                        ),
                    ]
                },
            ]
        }
        let object: [String: Any] = ["questions": questions]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    private func focusedTarget() -> NotificationDebugTarget? {
        guard let tabManager = AppDelegate.shared?.tabManager,
              let workspaceId = tabManager.selectedTabId else { return nil }
        return NotificationDebugTarget(
            workspaceId: workspaceId,
            surfaceId: tabManager.focusedSurfaceId(for: workspaceId)
        )
    }

    private func displayName(for kind: String) -> String {
        switch kind {
        case "turn-complete":
            return String(localized: "debug.menu.notification.turnComplete", defaultValue: "Turn Complete")
        case "idle":
            return String(localized: "debug.menu.notification.idle", defaultValue: "Idle Reminder")
        case "needs-permission":
            return String(localized: "debug.menu.notification.needsPermission", defaultValue: "Needs Permission")
        case "error":
            return String(localized: "debug.menu.notification.error", defaultValue: "Error")
        case "cli":
            return String(localized: "debug.menu.notification.cli", defaultValue: "CLI")
        case "cli-reply":
            return String(localized: "debug.menu.notification.cliReply", defaultValue: "CLI Reply")
        case "osc":
            return String(localized: "debug.menu.notification.osc", defaultValue: "OSC")
        case "hook-failed":
            return String(localized: "debug.menu.notification.hookFailed", defaultValue: "Hook Failed")
        case "feed-permission":
            return String(localized: "debug.menu.notification.feedPermission", defaultValue: "Feed Permission")
        case "feed-exit-plan":
            return String(localized: "debug.menu.notification.feedExitPlan", defaultValue: "Feed Exit Plan")
        case "feed-question":
            return String(localized: "debug.menu.notification.feedQuestion", defaultValue: "Feed Question")
        case "feed-question-4opts":
            return String(localized: "debug.menu.notification.feedQuestion4", defaultValue: "Feed Question (4 Options)")
        case "feed-question-multiselect":
            return String(localized: "debug.menu.notification.feedQuestionMultiSelect", defaultValue: "Feed Question (Multi-select)")
        case "feed-question-multi":
            return String(localized: "debug.menu.notification.feedQuestionMultiple", defaultValue: "Feed Question (Multiple)")
        case "feed-question-many-options":
            return String(localized: "debug.menu.notification.feedQuestionMany", defaultValue: "Feed Question (Many Options)")
        default:
            return kind
        }
    }
}
#endif
