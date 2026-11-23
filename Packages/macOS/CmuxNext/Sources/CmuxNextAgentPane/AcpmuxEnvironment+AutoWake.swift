public import CmuxNextCompat
import Foundation

/// Auto's wake notice (plans/cmux-next/auto-mode/DESIGN.md, "Laptop wake"): when macOS wakes, acpmux
/// checks the chats it ran before the sleep, and gives up the ones the Cloud took over meanwhile.
/// The app only says that the Mac woke; what follows is acpmux's.
nonisolated extension AcpmuxEnvironment {
    /// The request acpmux takes the wake as. No params.
    static let autoSessionWakeMethod = "_acpmux/auto_session/wake"

    /// Tells this daemon that macOS woke, and answers whether it took the notice. It never starts a
    /// daemon: with none running there is no chat to check. An acpmux that predates Auto answers
    /// "method not found", which is nothing to report either.
    @discardableResult
    public func autoSessionWake(deadline: Duration = .seconds(5)) async -> Bool {
        (try? await AcpmuxStatusClient.call(socketPath: socketPath, method: Self.autoSessionWakeMethod, deadline: deadline)) != nil
    }

    /// The wake notice for the acpmux this app runs (``resolvedApp(build:mock:)``), off the caller's
    /// actor.
    @concurrent public static func relaySystemWake(build: BuildIdentity?) async {
        await resolvedApp(build: build, mock: false)?.autoSessionWake()
    }

    /// The wake notice, sent while the caller's own wake work runs, so neither waits for the other.
    /// The caller's task owns both and this returns when both ended: the Cloud service's wake
    /// observer (CloudService.swift).
    public static func relaySystemWake(build: BuildIdentity?, alongside work: () async -> Void) async {
        async let told: Void = relaySystemWake(build: build)
        await work()
        await told
    }
}
