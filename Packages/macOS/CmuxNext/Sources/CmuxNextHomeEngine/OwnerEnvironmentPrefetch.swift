import Foundation

/// The Chief owner's `CMUX_TUI_CHIEF_BRAINS` value, started when the owner's run task begins and awaited when `server ensure`
/// spawns the owner. Its slow part (acpmux's team-signature check reads the whole executable) then overlaps
/// the build-home adoption and the Chief adoption that run before the spawn, instead of following them.
/// The spawn still builds the rest of the environment itself (it records the build space, which only a spawn may),
/// and the value is the same one it built before: the daemon takes `CMUX_TUI_CHIEF_BRAINS` once, at its
/// start, and starts a Chief's brain from it when a non-default Chief is created later, so the check cannot
/// wait for the first such Chief (Multi-Chief S6, cmux-tui-core chief_brains.rs).
actor OwnerEnvironmentPrefetch {
    private let make: @Sendable () async -> String?
    private var task: Task<String?, Never>?

    init(make: @escaping @Sendable () async -> String?) {
        self.make = make
    }

    /// Starts the build now; later calls do nothing.
    func begin() {
        guard task == nil else { return }
        let make = make
        // task-owner: awaited by `value()`, which `server ensure`'s environment provider calls at most once per spawn
        task = Task { await make() }
    }

    /// The value, once built (starts it when `begin` did not run).
    func value() async -> String? {
        begin()
        guard let task else { return nil }
        return await task.value
    }

    /// Whether `begin` ran (tests).
    var isStarted: Bool { task != nil }
}
