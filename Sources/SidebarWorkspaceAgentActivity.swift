import CmuxSidebar
import CmuxWorkspaces
import Foundation

/// Workspace-level aggregate consumed by both sidebar renderers.
struct SidebarWorkspaceAgentActivity: Equatable, Sendable {
    let agents: [SidebarAgentActivity]
    private let bestActivityByCanonicalStatus: [String: SidebarAgentActivity]
    /// Active `workspace loading` leases contribute to the spinner but never
    /// become agent status labels.
    let manualLoadingCount: Int
    let activeCodingAgentCount: Int
    let hasUnknownState: Bool
    let primaryState: SidebarAgentResolvedState?
    let primaryElapsedStart: TimeInterval?

    init(agents: [SidebarAgentActivity], manualLoadingCount: Int = 0) {
        self.agents = agents
        self.manualLoadingCount = max(0, manualLoadingCount)
        var bestActivityByCanonicalStatus: [String: SidebarAgentActivity] = [:]
        bestActivityByCanonicalStatus.reserveCapacity(agents.count)
        for agent in agents {
            let canonicalStatusKey = Self.canonicalStatusKey(agent.statusKey)
            guard let existing = bestActivityByCanonicalStatus[canonicalStatusKey] else {
                bestActivityByCanonicalStatus[canonicalStatusKey] = agent
                continue
            }
            let agentRank = Self.stateActionabilityRank(agent.state)
            let existingRank = Self.stateActionabilityRank(existing.state)
            if agentRank < existingRank || (agentRank == existingRank && agent.id < existing.id) {
                bestActivityByCanonicalStatus[canonicalStatusKey] = agent
            }
        }
        self.bestActivityByCanonicalStatus = bestActivityByCanonicalStatus
        var runningCount = 0
        var hasNeedsInput = false
        var hasRunning = false
        var hasUnknown = false
        var hasIdle = false
        var oldestElapsedStart: TimeInterval?
        for agent in agents {
            switch agent.state {
            case .running:
                runningCount += 1
                hasRunning = true
                if let elapsedStart = agent.elapsedStart {
                    oldestElapsedStart = min(oldestElapsedStart ?? elapsedStart, elapsedStart)
                }
            case .needsInput:
                hasNeedsInput = true
            case .unknown:
                hasUnknown = true
            case .idle:
                hasIdle = true
            }
        }
        activeCodingAgentCount = runningCount + self.manualLoadingCount
        hasUnknownState = hasUnknown
        primaryElapsedStart = oldestElapsedStart
        primaryState = if hasNeedsInput {
            .needsInput
        } else if hasRunning {
            .running
        } else if hasUnknown {
            .unknown
        } else if hasIdle {
            .idle
        } else {
            nil
        }
    }

    func elapsed(at now: Date) -> TimeInterval? {
        guard let primaryElapsedStart else { return nil }
        let value = now.timeIntervalSince1970 - primaryElapsedStart
        guard value.isFinite else { return nil }
        return max(0, value)
    }

    func elapsedText(at now: Date) -> String? {
        elapsed(at: now).map(Self.compactElapsedText)
    }

    func activity(forStatusKey statusKey: String) -> SidebarAgentActivity? {
        bestActivityByCanonicalStatus[Self.canonicalStatusKey(statusKey)]
    }

    /// Rewrites structured status pills from the deterministic state model.
    /// Non-agent metadata is returned untouched. A structured row with a
    /// runtime binding but no trustworthy lifecycle is explicitly Unknown.
    func correctedStatusEntries(_ entries: [SidebarStatusEntry]) -> [SidebarStatusEntry] {
        entries.compactMap { entry in
            guard AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(entry.key) else {
                return entry
            }
            // A stale structured status record is not agent presence. If no
            // token/PID-bound activity owns it, omit it instead of turning a
            // historical pill into a visible Unknown agent.
            guard let activity = activity(forStatusKey: entry.key) else {
                return nil
            }
            let value = Self.localizedStateLabel(activity.state)
            let icon: String
            let color: String
            switch activity.state {
            case .running:
                icon = "bolt.fill"
                color = "#4C8DFF"
            case .needsInput:
                icon = "bell.fill"
                color = "#4C8DFF"
            case .idle:
                icon = "checkmark.circle.fill"
                color = "#34C759"
            case .unknown:
                icon = "questionmark.circle"
                color = "#8E8E93"
            }
            return SidebarStatusEntry(
                key: entry.key,
                value: value,
                icon: icon,
                color: color,
                url: entry.url,
                priority: entry.priority,
                format: entry.format,
                timestamp: entry.timestamp
            )
        }
    }

    static func resolve(
        evidence: [SidebarAgentActivityEvidence],
        manualLoadingCount: Int = 0
    ) -> Self {
        var mergedByID: [String: SidebarAgentActivityEvidence] = [:]
        for item in evidence where item.hasDeterministicPresence {
            if let existing = mergedByID[item.id] {
                mergedByID[item.id] = existing.merged(with: item)
            } else {
                mergedByID[item.id] = item
            }
        }
        let agents = mergedByID.values.map { item in
            let processLiveness = item.isHeuristicProcessDetection
                ? RestorableAgentProcessLiveness.unknown
                : item.processLiveness
            return SidebarAgentActivity(
                id: item.id,
                statusKey: item.statusKey,
                state: SidebarAgentResolvedState(
                    lifecycle: item.lifecycle,
                    processLiveness: processLiveness,
                    hasExactProcessIdentity: item.hasExactProcessIdentity
                        && !item.isHeuristicProcessDetection,
                    hasLiveLifecycleSignal: item.hasLiveLifecycleSignal,
                    hasDeterministicSignal: item.hasDeterministicPresence
                ),
                startedAt: item.startedAt
            )
        }.sorted { $0.id < $1.id }
        return Self(agents: agents, manualLoadingCount: manualLoadingCount)
    }

    static func compactElapsedText(seconds: TimeInterval) -> String {
        let wholeSeconds = boundedWholeElapsedSeconds(seconds)
        if wholeSeconds < 60 {
            return localizedCount(
                "sidebar.agentActivity.elapsed.seconds",
                defaultValue: "%llds",
                count: wholeSeconds
            )
        }
        let minutes = wholeSeconds / 60
        if minutes < 60 {
            return localizedCount(
                "sidebar.agentActivity.elapsed.minutes",
                defaultValue: "%lldm",
                count: minutes
            )
        }
        let hours = minutes / 60
        if hours < 24 {
            let remainder = minutes % 60
            return remainder == 0
                ? localizedCount(
                    "sidebar.agentActivity.elapsed.hours",
                    defaultValue: "%lldh",
                    count: hours
                )
                : String.localizedStringWithFormat(
                    String(
                        localized: "sidebar.agentActivity.elapsed.hoursMinutes",
                        defaultValue: "%lldh %lldm"
                    ),
                    Int64(hours),
                    Int64(remainder)
                )
        }
        let days = hours / 24
        let remainder = hours % 24
        return remainder == 0
            ? localizedCount(
                "sidebar.agentActivity.elapsed.days",
                defaultValue: "%lldd",
                count: days
            )
            : String.localizedStringWithFormat(
                String(
                    localized: "sidebar.agentActivity.elapsed.daysHours",
                    defaultValue: "%lldd %lldh"
                ),
                Int64(days),
                Int64(remainder)
            )
    }

    private static func localizedCount(
        _ key: StaticString,
        defaultValue: String.LocalizationValue,
        count: Int64
    ) -> String {
        String.localizedStringWithFormat(
            String(localized: key, defaultValue: defaultValue),
            count
        )
    }

    /// Numeric display bucket shared by both sidebar renderers. Seconds tick
    /// below one minute, minutes below one day, then hours; values outside a
    /// useful wall-clock range clamp before integer conversion.
    static func compactElapsedDisplayBucket(_ seconds: TimeInterval) -> Int64 {
        let wholeSeconds = boundedWholeElapsedSeconds(seconds)
        if wholeSeconds < 60 { return wholeSeconds }
        if wholeSeconds < 86_400 { return 60 + wholeSeconds / 60 }
        return 100_000 + wholeSeconds / 3_600
    }

    private static func boundedWholeElapsedSeconds(_ seconds: TimeInterval) -> Int64 {
        // Ten thousand years is well beyond any useful session duration and
        // remains exactly convertible to Int64 on every supported platform.
        let maximum: TimeInterval = 315_576_000_000
        guard seconds.isFinite else { return 0 }
        return Int64(min(max(0, seconds), maximum).rounded(.down))
    }

    static func localizedStateLabel(_ state: SidebarAgentResolvedState) -> String {
        switch state {
        case .running:
            return String(
                localized: "sidebar.agentActivity.state.running",
                defaultValue: "Running"
            )
        case .needsInput:
            return String(
                localized: "sidebar.agentActivity.state.needsInput",
                defaultValue: "Needs input"
            )
        case .idle:
            return String(
                localized: "sidebar.agentActivity.state.idle",
                defaultValue: "Idle"
            )
        case .unknown:
            return String(
                localized: "sidebar.agentActivity.state.unknown",
                defaultValue: "Unknown"
            )
        }
    }

    static func localizedElapsedTooltip(_ elapsed: String) -> String {
        String.localizedStringWithFormat(
            String(
                localized: "sidebar.agentActivity.elapsedTooltip",
                defaultValue: "Session elapsed: %@"
            ),
            elapsed
        )
    }

    static func localizedRunningCompactLabel(_ elapsed: String) -> String {
        String.localizedStringWithFormat(
            String(
                localized: "sidebar.agentActivity.runningCompactLabel",
                defaultValue: "Running · %@"
            ),
            elapsed
        )
    }

    static func localizedRunningAccessibilityLabel(_ elapsed: String) -> String {
        String.localizedStringWithFormat(
            String(
                localized: "sidebar.agentActivity.runningAccessibilityLabel",
                defaultValue: "Running, session elapsed: %@"
            ),
            elapsed
        )
    }

    static func localizedUnknownTooltip() -> String {
        String(
            localized: "sidebar.agentActivity.unknownTooltip",
            defaultValue: "Agent state is unavailable"
        )
    }

    static func canonicalStatusKey(_ key: String) -> String {
        key == "claude_code" ? "claude" : key
    }

    private static func stateActionabilityRank(_ state: SidebarAgentResolvedState) -> Int {
        switch state {
        case .needsInput: 0
        case .running: 1
        case .unknown: 2
        case .idle: 3
        }
    }
}
