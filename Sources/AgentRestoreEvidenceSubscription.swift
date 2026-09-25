import CmuxFoundation
import Darwin
import Foundation

/// Owns native subscriptions behind an AsyncStream; Dispatch cancellation is thread-safe.
/// The immutable handles are the only shared state, which justifies unchecked Sendable.
final class AgentRestoreEvidenceSubscription: @unchecked Sendable {
    let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let sources: [any DispatchSourceProtocol]

    init(process: AgentPIDProcessIdentity?, paths: [String], deadline: DispatchTime = .now() + .seconds(8)) {
        self.init(processes: process.map { [$0] } ?? [], paths: paths, deadline: deadline)
    }

    init(
        processes: [AgentPIDProcessIdentity],
        paths: [String],
        deadline: DispatchTime = .now() + .seconds(8)
    ) {
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.events = events
        self.continuation = continuation
        var sources: [any DispatchSourceProtocol] = []
        var subscribedPIDs = Set<pid_t>()
        for process in processes where subscribedPIDs.insert(process.pid).inserted {
            let source = DispatchSource.makeProcessSource(
                identifier: process.pid, eventMask: .exit, queue: .global(qos: .utility)
            )
            source.setEventHandler { continuation.yield(); continuation.finish() }
            sources.append(source)
        }
        for path in Set(paths) {
            let descriptor = open(path, O_EVTONLY | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .attrib, .extend],
                queue: .global(qos: .utility)
            )
            source.setEventHandler { continuation.yield(); continuation.finish() }
            source.setCancelHandler { close(descriptor) }
            sources.append(source)
        }
        // This non-async native subscription has no Task to own a deadline.
        // One timer bounds the RPC if the kernel cannot supply an observation.
        let timeout = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timeout.schedule(deadline: deadline)
        timeout.setEventHandler { continuation.yield(); continuation.finish() }
        sources.append(timeout)
        self.sources = sources
        continuation.onTermination = { @Sendable [weak self] _ in self?.cancelSources() }
        for source in sources { source.resume() }
    }

    func cancel() {
        continuation.finish()
        cancelSources()
    }

    private func cancelSources() { for source in sources { source.cancel() } }

    deinit { cancel() }
}
