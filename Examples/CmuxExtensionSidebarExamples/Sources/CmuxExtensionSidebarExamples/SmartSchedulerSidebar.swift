import CmuxSidebarProviderKit
import Foundation

public struct SmartSchedulerSidebar: CmuxContextualSidebarProvider {
    public enum Strategy: String, Sendable {
        case balanced
        case blockedFirst
        case smallWins
        case roundRobin

        var idSuffix: String { rawValue }

        var title: CmuxSidebarProviderLocalizedText {
            switch self {
            case .balanced:
                localized("example.sidebar.smartScheduler.balanced.title", "Smart Queue")
            case .blockedFirst:
                localized("example.sidebar.smartScheduler.blockedFirst.title", "Blocked First")
            case .smallWins:
                localized("example.sidebar.smartScheduler.smallWins.title", "Small Wins")
            case .roundRobin:
                localized("example.sidebar.smartScheduler.roundRobin.title", "Round Robin")
            }
        }

        var systemImageName: String {
            switch self {
            case .balanced:
                "wand.and.stars"
            case .blockedFirst:
                "exclamationmark.bubble"
            case .smallWins:
                "checkmark.seal"
            case .roundRobin:
                "arrow.triangle.2.circlepath"
            }
        }
    }

    private struct ScheduledWorkspace {
        let workspace: CmuxSidebarProviderWorkspace
        let originalIndex: Int
        let score: Double
        let ageSeconds: TimeInterval?
        let signals: Set<Signal>

        var needsAttention: Bool {
            score > 0 || workspace.unreadCount > 0 || workspace.latestNotificationText != nil
        }

        var primarySignal: Signal {
            if signals.contains(.blocked) { return .blocked }
            if signals.contains(.failed) { return .failed }
            if signals.contains(.ready) { return .ready }
            if signals.contains(.smallWin) { return .smallWin }
            if signals.contains(.aged) { return .aged }
            if signals.contains(.unread) { return .unread }
            if signals.contains(.remote) { return .remote }
            return .quiet
        }
    }

    private enum Signal: Hashable {
        case blocked
        case failed
        case ready
        case smallWin
        case aged
        case unread
        case remote
        case quiet

        var subtitle: CmuxSidebarProviderText {
            switch self {
            case .blocked:
                .localized(localized("example.sidebar.smartScheduler.reason.blocked", "Blocked"))
            case .failed:
                .localized(localized("example.sidebar.smartScheduler.reason.failed", "Failed"))
            case .ready:
                .localized(localized("example.sidebar.smartScheduler.reason.ready", "Ready to review"))
            case .smallWin:
                .localized(localized("example.sidebar.smartScheduler.reason.smallWin", "Small win"))
            case .aged:
                .localized(localized("example.sidebar.smartScheduler.reason.aged", "Aged unread"))
            case .unread:
                .localized(localized("example.sidebar.smartScheduler.reason.unread", "Unread"))
            case .remote:
                .localized(localized("example.sidebar.smartScheduler.reason.remote", "Remote attention"))
            case .quiet:
                .localized(localized("example.sidebar.smartScheduler.reason.quiet", "Quiet"))
            }
        }

        var icon: CmuxSidebarProviderIcon {
            switch self {
            case .blocked:
                CmuxSidebarProviderIcon(systemImageName: "exclamationmark.bubble.fill", foregroundColorHex: "#FFFFFF", backgroundColorHex: "#3F7DFF")
            case .failed:
                CmuxSidebarProviderIcon(systemImageName: "xmark.octagon.fill", foregroundColorHex: "#FFFFFF", backgroundColorHex: "#D54747")
            case .ready:
                CmuxSidebarProviderIcon(systemImageName: "checkmark.seal.fill", foregroundColorHex: "#FFFFFF", backgroundColorHex: "#2F9E58")
            case .smallWin:
                CmuxSidebarProviderIcon(systemImageName: "bolt.fill", foregroundColorHex: "#1C1C1E", backgroundColorHex: "#F2C94C")
            case .aged:
                CmuxSidebarProviderIcon(systemImageName: "clock.fill", foregroundColorHex: "#FFFFFF", backgroundColorHex: "#8B6BD6")
            case .unread:
                CmuxSidebarProviderIcon(systemImageName: "bell.fill", foregroundColorHex: "#FFFFFF", backgroundColorHex: "#4C8DFF")
            case .remote:
                CmuxSidebarProviderIcon(systemImageName: "network", foregroundColorHex: "#FFFFFF", backgroundColorHex: "#6F7A87")
            case .quiet:
                CmuxSidebarProviderIcon(systemImageName: "circle", foregroundColorHex: "#6F7A87", backgroundColorHex: "#E6E8EB")
            }
        }
    }

    public let strategy: Strategy
    public let descriptor: CmuxSidebarProviderDescriptor

    public init(strategy: Strategy) {
        self.strategy = strategy
        descriptor = CmuxSidebarProviderDescriptor(
            id: "com.example.cmux.sidebar.smart-scheduler.\(strategy.idSuffix)",
            title: strategy.title,
            subtitle: localized("example.sidebar.smartScheduler.subtitle", "Workspace scheduler"),
            systemImageName: strategy.systemImageName,
            isHostProvided: false
        )
    }

    public func render(snapshot: CmuxSidebarProviderSnapshot) -> CmuxSidebarProviderRenderModel {
        render(snapshot: snapshot, context: CmuxSidebarProviderRenderContext(now: Date()))
    }

    public func render(
        snapshot: CmuxSidebarProviderSnapshot,
        context: CmuxSidebarProviderRenderContext
    ) -> CmuxSidebarProviderRenderModel {
        let scheduled = snapshot.workspaces.enumerated().map { index, workspace in
            scheduledWorkspace(workspace, originalIndex: index, now: context.now)
        }
        let focusQueue = scheduled
            .filter(\.needsAttention)
            .sorted { lhs, rhs in precedes(lhs, rhs, strategy: strategy) }
        let quiet = scheduled
            .filter { !$0.needsAttention }
            .sorted { $0.originalIndex < $1.originalIndex }

        let sections = [
            section(
                id: "focus",
                title: localized("example.sidebar.smartScheduler.group.focus", "Focus Queue"),
                systemImageName: strategy.systemImageName,
                items: focusQueue
            ),
            section(
                id: "quiet",
                title: localized("example.sidebar.smartScheduler.group.quiet", "Quiet"),
                systemImageName: "checkmark.circle",
                items: quiet
            ),
        ]

        return renderModel(providerId: descriptor.id, snapshot: snapshot, sections: sections)
    }

    private func scheduledWorkspace(
        _ workspace: CmuxSidebarProviderWorkspace,
        originalIndex: Int,
        now: Date
    ) -> ScheduledWorkspace {
        var signals: Set<Signal> = []
        var score = 0.0
        let searchableText = [
            workspace.title,
            workspace.customDescription,
            workspace.latestNotificationText,
            workspace.latestSubmittedMessage,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()

        if workspace.unreadCount > 0 || workspace.latestNotificationIsUnread == true {
            signals.insert(.unread)
            score += 80 + Double(min(workspace.unreadCount, 5) * 4)
        }

        if isBlocked(workspace: workspace, searchableText: searchableText) {
            signals.insert(.blocked)
            score += 110
        }

        if containsAny(searchableText, ["failed", "failure", "error", "exit code", "conflict", "denied", "missing", "crash", "rejected", "timed out"]) {
            signals.insert(.failed)
            score += 90
        }

        if isReady(workspace: workspace, searchableText: searchableText) {
            signals.insert(.ready)
            score += 65
        }

        if isSmallWin(workspace: workspace, searchableText: searchableText) {
            signals.insert(.smallWin)
            score += 32
        }

        if remoteNeedsAttention(workspace) {
            signals.insert(.remote)
            score += 48
        }

        let ageSeconds = workspace.latestNotificationCreatedAt.map { max(0, now.timeIntervalSince($0)) }
        if let ageSeconds {
            score += min(55, ageSeconds / 180)
            if ageSeconds >= 30 * 60 {
                signals.insert(.aged)
            }
        }

        return ScheduledWorkspace(
            workspace: workspace,
            originalIndex: originalIndex,
            score: score,
            ageSeconds: ageSeconds,
            signals: signals.isEmpty ? [.quiet] : signals
        )
    }

    private func precedes(
        _ lhs: ScheduledWorkspace,
        _ rhs: ScheduledWorkspace,
        strategy: Strategy
    ) -> Bool {
        switch strategy {
        case .balanced:
            return scorePrecedes(lhs, rhs)
        case .blockedFirst:
            let lhsRank = blockedFirstRank(lhs)
            let rhsRank = blockedFirstRank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return scorePrecedes(lhs, rhs)
        case .smallWins:
            let lhsRank = smallWinsRank(lhs)
            let rhsRank = smallWinsRank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return scorePrecedes(lhs, rhs)
        case .roundRobin:
            let lhsRank = roundRobinRank(lhs)
            let rhsRank = roundRobinRank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.originalIndex < rhs.originalIndex
        }
    }

    private func scorePrecedes(_ lhs: ScheduledWorkspace, _ rhs: ScheduledWorkspace) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        switch (lhs.workspace.latestNotificationCreatedAt, rhs.workspace.latestNotificationCreatedAt) {
        case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
            return lhsDate < rhsDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.originalIndex < rhs.originalIndex
        }
    }

    private func blockedFirstRank(_ item: ScheduledWorkspace) -> Int {
        if item.signals.contains(.blocked) { return 0 }
        if item.signals.contains(.failed) { return 1 }
        if item.signals.contains(.unread) { return 2 }
        if item.signals.contains(.ready) { return 3 }
        return 4
    }

    private func smallWinsRank(_ item: ScheduledWorkspace) -> Int {
        if item.signals.contains(.blocked) { return 0 }
        if item.signals.contains(.smallWin) && item.signals.contains(.ready) { return 1 }
        if item.signals.contains(.smallWin) { return 2 }
        if item.signals.contains(.ready) { return 3 }
        if item.signals.contains(.failed) { return 4 }
        return 5
    }

    private func roundRobinRank(_ item: ScheduledWorkspace) -> Int {
        if item.signals.contains(.blocked) { return 0 }
        if item.signals.contains(.failed) { return 1 }
        if item.signals.contains(.unread) { return 2 }
        if item.signals.contains(.ready) { return 3 }
        return 4
    }

    private func section(
        id: String,
        title: CmuxSidebarProviderLocalizedText,
        systemImageName: String,
        items: [ScheduledWorkspace]
    ) -> CmuxSidebarProviderSection {
        CmuxSidebarProviderSection(
            id: id,
            treeSection: CmuxSidebarProviderTreeSection(
                id: id,
                title: title.defaultValue,
                titleText: title,
                subtitle: nil,
                systemImageName: systemImageName,
                projectRootPath: nil,
                workspaceIds: items.map(\.workspace.id)
            ),
            rows: items.map { row(for: $0) }
        )
    }

    private func row(for item: ScheduledWorkspace) -> CmuxSidebarProviderRow {
        let signal = item.primarySignal
        return CmuxSidebarProviderRow(
            id: item.workspace.id,
            title: item.workspace.title,
            workspaceId: item.workspace.id,
            accessory: .inspector,
            subtitle: subtitle(for: item, signal: signal),
            trailingText: item.workspace.latestNotificationCreatedAt.map { .relativeDate($0, style: .compact) },
            leadingIcon: signal.icon
        )
    }

    private func subtitle(for item: ScheduledWorkspace, signal: Signal) -> CmuxSidebarProviderText? {
        switch signal {
        case .unread:
            if let latest = trimmed(item.workspace.latestNotificationText) {
                return .plain(latest)
            }
            return signal.subtitle
        case .quiet:
            return trimmed(item.workspace.customDescription).map(CmuxSidebarProviderText.plain)
        default:
            return signal.subtitle
        }
    }

    private func isBlocked(workspace: CmuxSidebarProviderWorkspace, searchableText: String) -> Bool {
        remoteNeedsAttention(workspace) ||
            containsAny(searchableText, ["needs input", "approval", "approve", "blocked", "waiting for", "requires input", "question", "confirm", "permission"])
    }

    private func isReady(workspace: CmuxSidebarProviderWorkspace, searchableText: String) -> Bool {
        !workspace.pullRequestURLs.isEmpty ||
            containsAny(searchableText, ["ready", "done", "complete", "completed", "tests passed", "passed", "opened pr", "pull request", "review", "merge"])
    }

    private func isSmallWin(workspace: CmuxSidebarProviderWorkspace, searchableText: String) -> Bool {
        if containsAny(searchableText, ["small", "quick", "targeted", "bug", "fix", "docs", "typo", "lint", "test", "minor", "one-line"]) {
            return true
        }
        if !workspace.pullRequestURLs.isEmpty, workspace.unreadCount <= 1 {
            return true
        }
        let promptLength = workspace.latestSubmittedMessage?.count ?? Int.max
        return promptLength <= 220 && workspace.panelDirectories.count <= 2
    }

    private func remoteNeedsAttention(_ workspace: CmuxSidebarProviderWorkspace) -> Bool {
        guard trimmed(workspace.remoteDisplayTarget) != nil,
              let state = trimmed(workspace.remoteConnectionState)?.lowercased()
        else {
            return false
        }
        return state == "connecting" || state == "reconnecting" || state == "disconnected"
    }

    private func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}
