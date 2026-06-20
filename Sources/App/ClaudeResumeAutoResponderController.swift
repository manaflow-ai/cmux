import CmuxSettings
import Foundation

/// Reads the `terminal.claudeResumeMode` setting from the managed-UserDefaults
/// backbone (the same store every other terminal setting resolves through).
enum ClaudeResumeModeSettings {
    static let modeKey = "terminal.claudeResumeMode"

    static func mode(defaults: UserDefaults = .standard) -> ClaudeResumeMode {
        guard let raw = defaults.string(forKey: modeKey),
              let mode = ClaudeResumeMode(rawString: raw) else {
            return .ask
        }
        return mode
    }
}

/// Drives a one-shot ``ClaudeResumeAutoResponder`` for each pane cmux just
/// auto-resumed for a Claude agent. Mirrors `AgentHibernationController`'s timer
/// model: a private serial-queue `DispatchSourceTimer` hops to the main actor,
/// samples each armed pane's rendered screen, and — when Claude's
/// compacted-session resume menu appears — synthesizes the keys to pick the
/// configured option, then disarms.
///
/// This exists because Claude Code's resume menu is interactive-only (no CLI
/// flag / config skips it), so the only place to express "always resume full"
/// is here, where cmux owns the pane.
@MainActor
final class ClaudeResumeAutoResponderController {
    static let shared = ClaudeResumeAutoResponderController()

    private struct Entry {
        weak var panel: TerminalPanel?
        let responder: ClaudeResumeAutoResponder
        let deadline: Date
    }

    /// The menu appears within a second or two of `claude --resume`. Poll a few
    /// times a second and stop watching after the window (if the session wasn't
    /// compacted the menu never appears and we quietly give up).
    private static let pollInterval: TimeInterval = 0.4
    private static let watchWindow: TimeInterval = 45

    private let timerQueue = DispatchQueue(label: "com.cmux.claude-resume-auto-responder")
    private var timer: DispatchSourceTimer?
    private var entries: [UUID: Entry] = [:]

    private init() {}

    /// Arm a one-shot responder for a freshly auto-resumed Claude pane. No-op for
    /// `.ask`. Called from the session-restore path on the main actor.
    func arm(panel: TerminalPanel, mode: ClaudeResumeMode, now: Date = Date()) {
        guard mode != .ask else { return }
        entries[panel.id] = Entry(
            panel: panel,
            responder: ClaudeResumeAutoResponder(mode: mode),
            deadline: now.addingTimeInterval(Self.watchWindow)
        )
        startTimerIfNeeded()
    }

    private func startTimerIfNeeded() {
        guard timer == nil, !entries.isEmpty else { return }
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
        timer.setEventHandler {
            Task.detached(priority: .utility) {
                await MainActor.run {
                    ClaudeResumeAutoResponderController.shared.tick(now: Date())
                }
            }
        }
        timer.resume()
        self.timer = timer
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func tick(now: Date) {
        for id in Array(entries.keys) {
            guard let entry = entries[id] else { continue }
            // Drop panes that went away or outlived the watch window.
            guard let panel = entry.panel, now < entry.deadline else {
                entries.removeValue(forKey: id)
                continue
            }
            guard panel.surface.hasLiveSurface else { continue }
            guard let screen = TerminalController.shared.readTerminalTextForSnapshot(
                terminalPanel: panel,
                includeScrollback: false,
                lineLimit: nil,
                allowVTExport: false
            ) else { continue }
            if let keys = entry.responder.evaluate(screen: screen) {
                for key in keys {
                    _ = panel.sendNamedKeyResult(key.namedKey)
                }
                entries.removeValue(forKey: id)
            }
        }
        if entries.isEmpty { stopTimer() }
    }
}
