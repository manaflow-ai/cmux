import AppKit
import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextSidebar
import Observation

/// The one app-wide reader of acpmux's `_acpmux/here` summary for the sidebar footer's Live button (RFD 0140; Leo
/// 2026-11-24: "an icon maybe toggle somewhere omnipresent... say the bottom left of the sidebar area"). Every
/// window's sidebar observes ``status``. It reads every ``interval`` while the app is active, and not at all while
/// it is in the background. A timeout or error keeps the last value (nil before the first), so a busy daemon never
/// reads as offline. Event-driven updates (a `here` subscription) are a follow-up.
@Observable @MainActor final class SidebarHereStatus {
    static let interval: Duration = .seconds(10)
    private(set) var status: SidebarLiveState.Status?
    @ObservationIgnored private var started = false

    /// Starts the reader once; later calls are no-ops.
    func start(build: BuildIdentity?, mock: Bool) {
        guard !started else { return }
        started = true
        // task-owner: app lifetime (one per app, reads every `interval` while active)
        Task { [weak self] in
            guard let env = await AcpmuxEnvironment.resolvedApp(build: build, mock: mock) else { return }
            while !Task.isCancelled {
                guard let self else { return }
                if NSApp?.isActive ?? false, let here = try? await env.here(deadline: AcpmuxEnvironment.answerDeadline) {
                    let next = Self.status(here.summary)
                    if let next, next != status { status = next }
                }
                do { try await Task.sleep(for: Self.interval) } catch { return }
            }
        }
    }

    /// The sidebar's value for the daemon's summary; nil for a daemon without one. A newer sync state
    /// shows no sync line, never offline.
    nonisolated static func status(_ summary: AcpmuxHere.Summary?) -> SidebarLiveState.Status? {
        guard let summary else { return nil }
        let sync: SidebarLiveState.Status.Sync? = switch summary.sync {
        case .offline: .offline
        case .syncing: .syncing
        case .synced: .synced
        case .alone: .alone
        case .unknown: nil
        }
        return SidebarLiveState.Status(sync: sync, pendingEdits: summary.pendingEdits, others: summary.others, agents: summary.agents)
    }
}
