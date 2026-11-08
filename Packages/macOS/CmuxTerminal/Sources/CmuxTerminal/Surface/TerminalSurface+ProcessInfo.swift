internal import Darwin
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

    /// The controlling TTY device name (e.g. `/dev/ttys003`) captured for this
    /// surface's current PTY lifecycle, or `nil` when there is no live runtime
    /// surface or the runtime has no TTY. Every process in the pane (shell,
    /// descendants, and background jobs) shares this controlling TTY.
    @MainActor
    public func controllingTTYName() -> String? {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "processInfo.ttyName") else {
            return nil
        }
        if runtimeControllingTTYName == nil {
            // Ghostty starts its PTY on the IO thread, so the eager lookup at
            // runtime installation can race before the device exists. Retry
            // only until the lifecycle acquires a TTY, then serve the cache.
            cacheControllingTTYIdentity(for: surface)
        }
        return runtimeControllingTTYName
    }

    /// The character-device identifier captured for the current PTY lifecycle.
    ///
    /// The identifier is resolved once Ghostty's asynchronous PTY startup makes
    /// it available, so delivery-time process routing can compare devices without
    /// repeatedly allocating a TTY name or accessing the filesystem.
    @MainActor
    public var controllingTTYDeviceIdentifier: Int64? {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "processInfo.ttyDevice") else {
            return nil
        }
        if runtimeControllingTTYName == nil {
            cacheControllingTTYIdentity(for: surface)
        }
        return runtimeControllingTTYDeviceIdentifier
    }

    @MainActor
    func cacheControllingTTYIdentity(for surface: ghostty_surface_t) {
        guard runtimeControllingTTYName == nil else { return }
        let exported = ghostty_surface_tty_name(surface)
        defer { ghostty_string_free(exported) }
        guard let ptr = exported.ptr, exported.len > 0 else { return }
        let data = Data(bytes: ptr, count: Int(exported.len))
        guard let decoded = String(data: data, encoding: .utf8) else { return }
        let name = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        runtimeControllingTTYName = name
        runtimeControllingTTYDeviceIdentifier = ttyDeviceIdentifier(for: name)
    }

    private func ttyDeviceIdentifier(for ttyName: String) -> Int64? {
        let path = ttyName.hasPrefix("/dev/") ? ttyName : "/dev/\(ttyName)"
        var statInfo = stat()
        guard stat(path, &statInfo) == 0 else { return nil }
        return Int64(statInfo.st_rdev)
    }
}
