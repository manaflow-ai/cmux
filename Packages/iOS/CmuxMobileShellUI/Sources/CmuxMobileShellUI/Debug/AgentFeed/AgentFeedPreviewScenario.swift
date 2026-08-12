#if DEBUG && os(iOS)
import CmuxMobileShellModel
import Foundation

enum AgentFeedPreviewScenario: String, CaseIterable {
    case empty
    case mixed
    case newActivity = "new-activity"
    case reply
    case permission
    case plan
    case questions
    case toolError = "tool-error"
    case expired
    case offline
    case reconnect
    case exactNavigation = "exact-navigation"
    case capabilityGap = "capability-gap"
    case malformed
    case japanese
    case accessibility
    case stress

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Self {
        let environmentValue = environment["CMUX_UITEST_AGENT_FEED_SCENARIO"]
        let assignmentValue = arguments.first { $0.hasPrefix("CMUX_UITEST_AGENT_FEED_SCENARIO=") }?
            .split(separator: "=", maxSplits: 1).last.map(String.init)
        let flagIndex = arguments.firstIndex(of: "--agent-feed-scenario")
        let flagValue = flagIndex.flatMap { index in
            arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        }
        // XCUITest can relaunch the same application identity several times in
        // one method. Prefer the per-launch argument so a prior process's
        // inherited environment cannot select the next fixture.
        return Self(rawValue: flagValue ?? assignmentValue ?? environmentValue ?? "mixed") ?? .mixed
    }
}

struct AgentFeedPreviewConfiguration {
    let scenario: AgentFeedPreviewScenario
    let items: [MobileAgentFeedItem]
    let status: MobileAgentFeedStatus
    let filter: MobileAgentFeedFilter
    let hostEventCount: Int

    static func current() -> Self { fixture(for: .resolve()) }

    static func fixture(for scenario: AgentFeedPreviewScenario) -> Self {
        switch scenario {
        case .empty:
            return Self(scenario: scenario, items: [], status: .loading, filter: .needsInput, hostEventCount: 0)
        case .mixed, .accessibility:
            return Self(scenario: scenario, items: mixedItems, status: .ready, filter: .allActivity, hostEventCount: 12)
        case .japanese:
            return Self(scenario: scenario, items: japaneseItems, status: .ready, filter: .allActivity, hostEventCount: 1)
        case .newActivity:
            return Self(scenario: scenario, items: activityItems, status: .ready, filter: .allActivity, hostEventCount: 36)
        case .reply:
            return one(scenario, item: replyItem)
        case .permission:
            return one(scenario, item: permissionItem)
        case .plan:
            return one(scenario, item: planItem)
        case .questions:
            return one(scenario, item: questionItem)
        case .toolError:
            return one(scenario, item: toolErrorItem, filter: .allActivity)
        case .expired:
            return one(scenario, item: expiredItem, filter: .allActivity)
        case .offline:
            return Self(scenario: scenario, items: [offlineItem], status: .offlineCached, filter: .needsInput, hostEventCount: 1)
        case .reconnect:
            return Self(scenario: scenario, items: [reconnectingItem], status: .reconnecting, filter: .allActivity, hostEventCount: 2)
        case .exactNavigation:
            return one(scenario, item: planItem)
        case .capabilityGap:
            return Self(scenario: scenario, items: [], status: .requiresMacUpdate, filter: .allActivity, hostEventCount: 0)
        case .malformed:
            return Self(scenario: scenario, items: malformedItems, status: .ready, filter: .allActivity, hostEventCount: 2)
        case .stress:
            return Self(
                scenario: scenario,
                items: Array(stressItems.prefix(300)),
                status: .ready,
                filter: .allActivity,
                hostEventCount: stressHostEventCount
            )
        }
    }

    static let permissionItem = item(
        id: 101,
        source: "codex",
        kind: "permissionRequest",
        title: "Codex needs permission",
        payload: .permission(
            requestID: "permission-101",
            toolName: "Bash",
            safeInput: "command: …, timeout: …",
            supportedModes: ["once", "always", "deny"]
        )
    )

    static var japaneseItems: [MobileAgentFeedItem] {
        let localizer = AgentFeedLocalizer()
        return [item(
            id: 111,
            source: "codex",
            kind: "permissionRequest",
            title: localizer.string(
                "mobile.agentFeed.fixture.japanese.title",
                defaultValue: "Codex is requesting permission"
            ),
            payload: .permission(
                requestID: "permission-111",
                toolName: localizer.string(
                    "mobile.agentFeed.fixture.japanese.tool",
                    defaultValue: "Shell command"
                ),
                safeInput: localizer.string(
                    "mobile.agentFeed.fixture.japanese.input",
                    defaultValue: "Command: run focused verification"
                ),
                supportedModes: ["once", "always", "deny"]
            ),
            macDisplayName: localizer.string(
                "mobile.agentFeed.fixture.japanese.computer",
                defaultValue: "Development Mac"
            ),
            workstreamID: "検証-1",
            cwd: "/プロジェクト/エージェントフィード"
        )]
    }

    static let planItem = item(
        id: 102,
        source: "claude",
        kind: "exitPlan",
        title: "Claude finished a plan",
        payload: .exitPlan(
            requestID: "plan-102",
            plan: (1...24).map { "\($0). Validate the authenticated feed, exact routing, and recovery behavior." }.joined(separator: "\n"),
            summary: "Review the iOS Agent Feed plan",
            defaultMode: "manual"
        ),
        macIndex: 1
    )

    static let questionItem = item(
        id: 103,
        source: "gemini",
        kind: "question",
        title: "Gemini has two questions",
        payload: .question(requestID: "question-103", questions: [
            .init(
                id: "scope",
                header: "Scope",
                prompt: "Which clients should receive the feed?",
                multiSelect: true,
                options: [
                    .init(id: "iphone", label: "iPhone", description: "The signed iOS client"),
                    .init(id: "ipad", label: "iPad", description: "The tablet layout"),
                ]
            ),
            .init(
                id: "priority",
                header: "Priority",
                prompt: "Which request should appear first?",
                multiSelect: false,
                options: [
                    .init(id: "blocking", label: "Blocking requests"),
                    .init(id: "recent", label: "Most recent activity"),
                ]
            ),
        ]),
        macIndex: 2
    )

    static let replyItem = item(
        id: 104,
        source: "opencode",
        kind: "stop",
        title: "OpenCode finished a turn",
        status: .telemetry,
        payload: .stop(reason: "Implementation is ready for a reply."),
        macIndex: 3
    )

    static let toolErrorItem = item(
        id: 105,
        source: "hermes-agent",
        kind: "toolResult",
        title: "Hermes command failed",
        status: .telemetry,
        payload: .toolResult(name: "swift test", result: "Exited with status 1", isError: true),
        macIndex: 4
    )

    static let expiredItem = item(
        id: 106,
        source: "codex",
        kind: "permissionRequest",
        title: "Agent disconnected before responding",
        status: .expired,
        payload: .permission(requestID: "expired-106", toolName: "Bash", safeInput: "command: …", supportedModes: ["once", "deny"]),
        macIndex: 5,
        connectionStatus: .unavailable
    )

    static let offlineItem = item(
        id: 107,
        source: "claude",
        kind: "permissionRequest",
        title: "Cached permission request",
        payload: .permission(requestID: "offline-107", toolName: "Write", safeInput: "path: …", supportedModes: ["once", "deny"]),
        connectionStatus: .unavailable
    )

    static let reconnectingItem = item(
        id: 108,
        source: "gemini",
        kind: "assistantMessage",
        title: "Reconnecting agent",
        status: .telemetry,
        payload: .message(text: "Connection recovery in progress", fromUser: false),
        connectionStatus: .reconnecting
    )

    static let malformedItems = [
        item(
            id: 109,
            source: "future-agent-v9",
            kind: "futureEvent",
            title: "Unknown agent event",
            status: .telemetry,
            payload: .unknown(kind: "futureEvent"),
            routeAvailable: false
        ),
        item(
            id: 110,
            source: "codex",
            kind: "question",
            title: "Malformed question payload",
            payload: .question(requestID: "malformed-110", questions: [])
        ),
    ]

    static var mixedItems: [MobileAgentFeedItem] {
        [permissionItem, planItem, questionItem, replyItem, toolErrorItem, expiredItem]
            + (6..<12).map { index in
                item(
                    id: 200 + index,
                    source: ["codex", "claude", "gemini", "opencode"][index % 4],
                    kind: "assistantMessage",
                    title: "Agent \(index + 1) activity",
                    status: .telemetry,
                    payload: .message(text: "Deterministic activity from agent \(index + 1)", fromUser: false),
                    macIndex: index
                )
            }
    }

    static var activityItems: [MobileAgentFeedItem] {
        (0..<36).map { index in
            item(
                id: 300 + index,
                source: ["codex", "claude", "gemini"][index % 3],
                kind: "assistantMessage",
                minutesAgo: TimeInterval(index + 1),
                title: "Scrollable activity \(index + 1)",
                status: .telemetry,
                payload: .message(text: "Activity \(index + 1)", fromUser: false),
                macIndex: index % 12
            )
        }
    }

    static var stressSnapshots: [[MobileAgentFeedItem]] {
        (0..<12).map { agent in
            (0..<200).map { event in
                let sequence = agent * 200 + event
                let actionable = sequence % 10 == 0
                return item(
                    id: 10_000 + sequence,
                    source: ["codex", "claude", "gemini", "opencode", "hermes-agent"][agent % 5],
                    kind: actionable ? "permissionRequest" : "assistantMessage",
                    minutesAgo: TimeInterval(sequence) / 10,
                    title: actionable ? "Agent \(agent + 1) needs input" : "Agent \(agent + 1) event \(event + 1)",
                    status: actionable ? .pending : .telemetry,
                    payload: actionable
                        ? .permission(requestID: "stress-\(sequence)", toolName: "Bash", safeInput: "command: …", supportedModes: ["once", "deny"])
                        : .message(text: "Stress event \(sequence + 1)", fromUser: false),
                    macIndex: agent
                )
            }
        }
    }

    static let stressHostEventCount = 2_400
    static let stressRetainedItemLimit = MobileAgentFeedAggregation.maxItemCount

    static var stressItems: [MobileAgentFeedItem] {
        MobileAgentFeedAggregation().items(from: stressSnapshots)
    }

    static func injectedActivityBurst() -> [MobileAgentFeedItem] {
        (0..<100).map { index in
            item(
                id: 900 + index,
                source: ["codex", "claude", "gemini"][index % 3],
                kind: "assistantMessage",
                minutesAgo: -TimeInterval(index + 1) / 10,
                title: "New activity burst \(index + 1)",
                status: .telemetry,
                payload: .message(text: "Burst event \(index + 1)", fromUser: false),
                macIndex: index % 12
            )
        }
    }

    static func reconciledItems() -> [MobileAgentFeedItem] {
        let connected = item(
            id: 108,
            source: "gemini",
            kind: "assistantMessage",
            minutesAgo: 0,
            title: "Reconnected without duplicate",
            status: .telemetry,
            payload: .message(text: "Authoritative snapshot won", fromUser: false),
            connectionStatus: .connected
        )
        return MobileAgentFeedAggregation().items(from: [[reconnectingItem], [connected]])
    }

    private static func one(
        _ scenario: AgentFeedPreviewScenario,
        item: MobileAgentFeedItem,
        filter: MobileAgentFeedFilter = .needsInput
    ) -> Self {
        Self(scenario: scenario, items: [item], status: .ready, filter: filter, hostEventCount: 1)
    }

    private static func item(
        id: Int,
        source: String,
        kind: String,
        minutesAgo: TimeInterval = 1,
        title: String,
        status: MobileWorkstreamFeedStatus = .pending,
        payload: MobileWorkstreamFeedPayload,
        macIndex: Int = 0,
        connectionStatus: MobileMacConnectionStatus = .connected,
        macDisplayName: String? = nil,
        workstreamID: String? = nil,
        cwd: String? = "/cmux/worktrees/agent-feed",
        routeAvailable: Bool = true
    ) -> MobileAgentFeedItem {
        let date = Date(timeIntervalSince1970: 1_800_000_000 - minutesAgo * 60)
        let uuid = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!
        let macDeviceID = switch macIndex {
        case 0: "macbook"
        case 1: "mac-studio"
        default: "mac-\(macIndex + 1)"
        }
        let defaultMacDisplayName = switch macIndex {
        case 0: "MacBook Pro"
        case 1: "Studio"
        default: "Mac \(macIndex + 1)"
        }
        return MobileAgentFeedItem(
            macDeviceID: macDeviceID,
            macInstanceTag: "fixture",
            macDisplayName: macDisplayName ?? defaultMacDisplayName,
            connectionStatus: connectionStatus,
            wire: MobileWorkstreamFeedListItem(
                id: uuid,
                workstreamID: workstreamID ?? "\(source)-fixture-\(macIndex + 1)",
                source: source,
                kind: kind,
                createdAt: date,
                updatedAt: date,
                cwd: cwd,
                title: title,
                workspaceID: routeAvailable ? "workspace-\(macIndex + 1)" : nil,
                surfaceID: routeAvailable ? "surface-\(id)" : nil,
                status: status,
                payload: payload
            )
        )
    }
}
#endif
