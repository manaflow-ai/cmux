package import Foundation

/// Coalesces local stop and authenticated cleanup of one enrollment, including failed startup.
package actor NativeCloudLinkLease {
    private let child: any NativeCloudLink
    private let stopEnrollment: @Sendable () async -> Void
    private let revokeEnrollment: @Sendable () async throws -> Void
    private var stopping: Task<Void, Never>?
    private var revoking: Task<Void, Error>?

    package init(child: any NativeCloudLink, stop: @escaping @Sendable () async -> Void,
                 revoke: @escaping @Sendable () async throws -> Void) {
        self.child = child; stopEnrollment = stop; revokeEnrollment = revoke
    }
    package func socketPath() async throws -> String {
        guard stopping == nil else { throw CancellationError() }
        let socket = try await child.socketPath()
        guard stopping == nil else { throw CancellationError() }
        return socket
    }
    package func currentSocketPath() async -> String? {
        guard stopping == nil else { return nil }
        return await child.currentSocketPath()
    }
    package func stop() async {
        if let stopping { await stopping.value; return }
        let task = Task { [child, stopEnrollment] in await stopEnrollment(); await child.stop() }
        stopping = task
        await task.value
    }
    package func revoke() async throws {
        await stop()
        if let revoking { try await revoking.value; return }
        let task = Task { [revokeEnrollment] in try await revokeEnrollment() }
        revoking = task
        do { try await task.value }
        catch { if revoking == task { revoking = nil }; throw error }
    }
}
