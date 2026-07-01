import CmuxSettings
import Foundation

/// Drives a one-shot ``ClaudeResumeAutoResponder`` for each pane cmux just
/// auto-resumed for a Claude agent. Mirrors `AgentHibernationController`'s
/// bounded timer model: a main-queue `DispatchSourceTimer` samples each armed
/// pane's rendered screen and — when Claude's compacted-session resume menu
/// appears — synthesizes the keys to pick the configured option, then disarms.
///
/// This exists because Claude Code's resume menu is interactive-only (no CLI
/// flag / config skips it), so the only place to express "always resume full"
/// is here, where cmux owns the pane.
@MainActor
final class ClaudeResumeAutoResponderController {
    static let shared = ClaudeResumeAutoResponderController()
    private static let modeKey = "terminal.claudeResumeMode"

    /// The menu appears within a second or two of `claude --resume`. Poll a few
    /// times a second and stop watching after the window (if the session wasn't
    /// compacted the menu never appears and we quietly give up).
    private static let pollInterval: TimeInterval = 0.4
    /// Bound failed restore/startup cases that never produce a live surface. This
    /// is deliberately much longer than the live watch window so paced restore
    /// and cold hidden panes can still start their prompt watch when they become
    /// live.
    private static let pendingWindow: TimeInterval = 30 * 60
    private static let watchWindow: TimeInterval = 45
    /// Cap snapshot reads per tick so a large restore (~1000 panes) spreads the
    /// work across ticks instead of doing an O(N) sweep every poll.
    private static let maxEntriesPerTick = 24

    private var timer: DispatchSourceTimer?
    private let panels = NSMapTable<NSString, TerminalPanel>.strongToWeakObjects()
    private var responders: [UUID: ClaudeResumeAutoResponder] = [:]
    private var pendingDeadlines: [UUID: Date] = [:]
    private var deadlines: [UUID: Date] = [:]
    private var pollCursor = 0

    private init() {}

    /// Arm a one-shot responder for a freshly auto-resumed Claude pane. No-op for
    /// `.ask`. Called from the session-restore path on the main actor.
    func arm(panel: TerminalPanel, now: Date = Date()) {
        let mode = Self.mode()
        guard mode != .ask else { return }
        panels.setObject(panel, forKey: Self.panelKey(for: panel.id))
        responders[panel.id] = ClaudeResumeAutoResponder(mode: mode)
        pendingDeadlines[panel.id] = now.addingTimeInterval(Self.pendingWindow)
        if panel.surface.hasLiveSurface {
            deadlines[panel.id] = now.addingTimeInterval(Self.watchWindow)
        } else {
            deadlines.removeValue(forKey: panel.id)
        }
        startTimerIfNeeded()
    }

    private func startTimerIfNeeded() {
        guard timer == nil, !responders.isEmpty else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
        timer.setEventHandler {
            MainActor.assumeIsolated {
                ClaudeResumeAutoResponderController.shared.tick(now: Date())
            }
        }
        timer.resume()
        self.timer = timer
    }

    private static func mode(defaults: UserDefaults = .standard) -> ClaudeResumeMode {
        guard let raw = defaults.string(forKey: modeKey),
              let mode = ClaudeResumeMode(rawString: raw) else {
            return .ask
        }
        return mode
    }

    private static func panelKey(for id: UUID) -> NSString {
        id.uuidString as NSString
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func tick(now: Date) {
        let ids = Array(responders.keys)
        guard !ids.isEmpty else { stopTimer(); return }
        // Round-robin a bounded batch per tick so a large restore doesn't do an
        // O(N) sweep (and N terminal reads) every 0.4s on the main actor.
        let count = min(Self.maxEntriesPerTick, ids.count)
        for offset in 0..<count {
            let id = ids[(pollCursor + offset) % ids.count]
            guard let responder = responders[id] else { continue }
            // Drop panes that went away.
            guard let panel = panels.object(forKey: Self.panelKey(for: id)) else {
                removeEntry(id)
                continue
            }
            guard let pendingDeadline = pendingDeadlines[id],
                  now < pendingDeadline else {
                removeEntry(id)
                continue
            }
            guard panel.surface.hasLiveSurface else { continue }
            let deadline = liveDeadline(for: id, now: now)
            guard now < deadline else {
                removeEntry(id)
                continue
            }
            guard let screen = TerminalController.shared.readTerminalTextForSnapshot(
                terminalPanel: panel,
                includeScrollback: false,
                lineLimit: nil,
                allowVTExport: false
            ) else { continue }
            if let keys = responder.evaluate(screen: screen) {
                guard deliver(keys, to: panel) else {
                    continue
                }
                responder.confirmDelivered()
                removeEntry(id)
            }
        }
        pollCursor = (pollCursor + count) % max(ids.count, 1)
        if responders.isEmpty { stopTimer() }
    }

    private func liveDeadline(for id: UUID, now: Date) -> Date {
        if let deadline = deadlines[id] {
            return deadline
        }
        let deadline = now.addingTimeInterval(Self.watchWindow)
        deadlines[id] = deadline
        return deadline
    }

    private func removeEntry(_ id: UUID) {
        panels.removeObject(forKey: Self.panelKey(for: id))
        responders.removeValue(forKey: id)
        pendingDeadlines.removeValue(forKey: id)
        deadlines.removeValue(forKey: id)
    }

    private func deliver(_ keys: [ClaudeResumeKey], to panel: TerminalPanel) -> Bool {
        for key in keys {
            let result = panel.sendNamedKeyResult(key.namedKey)
            guard result.accepted else { return false }
        }
        return true
    }
}
