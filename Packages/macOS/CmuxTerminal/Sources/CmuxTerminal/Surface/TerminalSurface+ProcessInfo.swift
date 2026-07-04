public import Foundation
public import GhosttyKit

// MARK: - Foreground process / controlling-tty introspection

extension TerminalSurface {
    /// The foreground process id reported by libghostty for this surface's PTY,
    /// or `nil` when there is no live runtime surface. Used by the per-pane
    /// runaway-memory guardrail to name the foreground command in its warning.
    @MainActor
    public func foregroundProcessID() -> Int? {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "memGuard.foregroundPID") else {
            return nil
        }
        let pid = ghostty_surface_foreground_pid(surface)
        return pid > 0 ? Int(pid) : nil
    }

    /// The controlling TTY device name (e.g. `/dev/ttys003`) for this surface's
    /// PTY, or `nil` when there is no live runtime surface or the runtime has no
    /// tty yet. Every process in the pane (shell + descendants + background jobs)
    /// shares this controlling tty, so it is the attribution key the guardrail
    /// sums process-tree memory by.
    @MainActor
    public func controllingTTYName() -> String? {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "memGuard.ttyName") else {
            return nil
        }
        let exported = ghostty_surface_tty_name(surface)
        defer { ghostty_string_free(exported) }
        guard let ptr = exported.ptr, exported.len > 0 else { return nil }
        let data = Data(bytes: ptr, count: Int(exported.len))
        guard let decoded = String(data: data, encoding: .utf8) else { return nil }
        let name = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
