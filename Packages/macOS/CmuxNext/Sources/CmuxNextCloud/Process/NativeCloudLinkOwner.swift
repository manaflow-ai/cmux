package import Foundation
import os

/// Owns the selected scope's child; earlier enrollments remain available for sign-out cleanup.
package actor NativeCloudLinkOwner {
    package typealias Factory = @Sendable (CloudTeamScope.Snapshot) async throws -> NativeCloudLinkLease
    private let make: Factory
    private let invalidate: @Sendable () async throws -> Void
    private var active = false
    private var generation: UInt64 = 0
    private var current: (scope: String, lease: NativeCloudLinkLease)?
    private var published: (scope: String, socket: String)?
    private var starting: Task<String, Error>?
    private var startingScope: String?
    private var shutdown: Task<Void, Never>?
    /// Bounded within one sign-in. Local selection changes never discard an authenticated cleanup handle.
    private var cleanup: [NativeCloudLinkLease] = []
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cloud.native")

    package init(make: @escaping Factory, invalidate: @escaping @Sendable () async throws -> Void) {
        self.make = make; self.invalidate = invalidate
    }
    package func resume() async {
        while let shutdown {
            await shutdown.value
            if self.shutdown == shutdown { self.shutdown = nil }
        }
        guard !Task.isCancelled else { return }
        active = true
    }
    package func ensure(_ scope: CloudTeamScope.Snapshot) async throws -> String {
        guard active else { throw NativeDeviceEnrollmentError.signedOut }
        if let starting, startingScope == scope.id { return try await starting.value }
        let previous = starting, epoch = generation
        let task = Task { [weak self] in
            _ = await previous?.result
            guard let self else { throw CancellationError() }
            return try await self.run(scope, epoch: epoch)
        }
        starting = task; startingScope = scope.id
        defer { if starting == task { starting = nil; startingScope = nil } }
        return try await task.value
    }
    private func check(_ scope: CloudTeamScope.Snapshot, epoch: UInt64) async throws {
        try Task.checkCancellation()
        guard active, epoch == generation else { throw CancellationError() }
        try await scope.recheck()
        guard active, epoch == generation else { throw CancellationError() }
    }
    private func run(_ scope: CloudTeamScope.Snapshot, epoch: UInt64) async throws -> String {
        try await check(scope, epoch: epoch)
        if current?.scope != scope.id {
            let old = current; current = nil; published = nil
            if old != nil {
                do { try await invalidate() }
                catch { await old?.lease.stop(); throw error }
            }
            await old?.lease.stop()
            try await check(scope, epoch: epoch)
        }
        if current == nil {
            guard cleanup.count < 256 else { throw NativeDeviceEnrollmentError.busy }
            let lease = try await make(scope)
            cleanup.append(lease)
            do { try await check(scope, epoch: epoch) }
            catch { await lease.stop(); throw error }
            current = (scope.id, lease)
        }
        guard let lease = current?.lease else { throw CancellationError() }
        do {
            if await lease.currentSocketPath() == nil {
                let replacing = published != nil
                published = nil
                if replacing { try await invalidate() } // A replacement can reuse the same path.
                try await check(scope, epoch: epoch)
            }
            let socket = try await lease.socketPath()
            try await check(scope, epoch: epoch)
            if published?.scope != scope.id || published?.socket != socket {
                if published != nil { try await invalidate() }
                try await check(scope, epoch: epoch)
                published = (scope.id, socket)
            }
            return socket
        } catch {
            if current?.lease === lease { current = nil; published = nil; try? await invalidate() }
            await lease.stop()
            throw error
        }
    }
    /// Observes only: listing a team never enrolls or starts its link.
    package func socket(for scope: CloudTeamScope.Snapshot) async throws -> String? {
        try await scope.recheck()
        if let current, current.scope != scope.id {
            await retire()
            try await scope.recheck()
            return nil
        }
        guard active, current?.scope == scope.id, published?.scope == scope.id,
              let lease = current?.lease else { return nil }
        let socket = await lease.currentSocketPath()
        try await scope.recheck()
        guard current?.lease === lease, published?.socket == socket, socket != nil else {
            published = nil
            try await invalidate()
            return nil
        }
        return socket
    }
    /// A picker or policy change stops local transport; it preserves enrollment cleanup until sign-out.
    package func retire() async {
        generation &+= 1
        let job = starting, old = current
        starting = nil; startingScope = nil; current = nil; published = nil
        job?.cancel()
        do { try await invalidate() }
        catch { logger.info("Native transport retired while its daemon was unavailable") }
        await old?.lease.stop()
        _ = await job?.result
    }
    /// Quit stops local work without deleting a device registration needed at the next launch.
    package func suspend() async { active = false; await retire() }

    /// All local transport ends before authenticated revocations and before the parent's key rotation.
    package func end() async {
        active = false
        if let shutdown { await shutdown.value; return }
        let task = Task { [weak self] () -> Void in _ = await self?.finish() }
        shutdown = task
        await task.value
    }
    private func finish() async {
        await retire()
        let leases = cleanup; cleanup.removeAll()
        for lease in leases {
            do { try await lease.revoke() }
            catch { logger.error("Native enrollment cleanup deferred: \(String(describing: error), privacy: .public)") }
        }
    }
}
