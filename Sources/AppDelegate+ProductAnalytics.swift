import AppKit
import CMUXAgentLaunch
import CmuxProductAnalytics

extension AppDelegate {
    /// Starts product analytics for the launch: records the launch itself and
    /// counts agent sessions from accepted hook events. No-op when telemetry
    /// is off, because ``ProductAnalytics/app`` is then disabled.
    func startProductAnalytics() {
        let analytics = ProductAnalytics.app
        guard analytics.isEnabled else { return }
        refreshProductAnalyticsActivityContext()
        Task { @MainActor in
            for await notification in NotificationCenter.default.notifications(named: .workstreamEventReceived) {
                guard let event = notification.object as? WorkstreamEvent else { continue }
                analytics.noteAgentHook(
                    source: event.source,
                    sessionID: event.sessionId,
                    phase: Self.agentHookPhase(event.hookEventName)
                )
            }
        }
    }

    /// Refreshes the open-workspace count carried by later events. Runs on
    /// activation (before the daily active event) and whenever a window's
    /// workspace count changes.
    func refreshProductAnalyticsActivityContext() {
        let analytics = ProductAnalytics.app
        guard analytics.isEnabled else { return }
        let count = mainWindowContexts.values.reduce(0) { $0 + $1.tabManager.tabs.count }
        analytics.updateContext(.workspacesOpen(count))
    }

    nonisolated static func agentHookPhase(_ name: WorkstreamEvent.HookEventName) -> AgentHookPhase {
        switch name {
        case .sessionStart: .sessionStart
        case .sessionEnd: .sessionEnd
        default: .activity
        }
    }
}
