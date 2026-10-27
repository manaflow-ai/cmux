import CmuxNextCompat
public import CmuxNextWakeups
public import Foundation

/// A ``ProcessLauncher`` that records each spawn it runs: whether it ran on the main thread and the child's
/// quality of service at that moment. A start that spawns by itself, without the injected launcher, records
/// nothing, so a test that expects one recorded spawn fails for it.
///
/// ```swift
/// let probe = SpawnProbe(childPriority: .userVisible)
/// let child = MobileHostProcess(launcher: probe.launcher)
/// try await child.start(launch, environment: [:], log: nil)
/// #expect(await probe.recorded() == [.init(onMain: false, qualityOfService: .default)])
/// ```
public struct SpawnProbe: Sendable {
    /// One spawn the launcher ran.
    public struct Spawn: Equatable, Sendable, CustomStringConvertible {
        /// The spawn ran on the main thread.
        public let onMain: Bool
        /// The child's quality of service when it was spawned.
        public let qualityOfService: QualityOfService

        public init(onMain: Bool, qualityOfService: QualityOfService) {
            self.onMain = onMain
            self.qualityOfService = qualityOfService
        }

        public var description: String { "spawn(onMain: \(onMain), qos: \(qualityOfService.rawValue))" }
    }

    /// The launcher to inject.
    public let launcher: ProcessLauncher
    private let spawns: AsyncStream<Spawn>
    private let continuation: AsyncStream<Spawn>.Continuation

    /// - Parameters:
    ///   - priority: the launcher's queue priority.
    ///   - childPriority: the children's priority (the launcher sets it before each spawn).
    public init(priority: WorkPriority = .userVisible, childPriority: WorkPriority) {
        // A test makes a few spawns; the cap only bounds a runaway one.
        let (spawns, continuation) = AsyncStream.makeStream(of: Spawn.self, bufferingPolicy: .bufferingOldest(64))
        self.spawns = spawns
        self.continuation = continuation
        launcher = ProcessLauncher(label: "com.cmuxterm.next.test.spawn-probe", priority: priority,
                                   childPriority: childPriority) { process in
            continuation.yield(Spawn(onMain: Thread.isMainThread, qualityOfService: process.qualityOfService))
            try process.blockingRun()
        }
    }

    /// The spawns so far, in order; the probe records none after this call.
    public func recorded() async -> [Spawn] {
        continuation.finish()
        var all: [Spawn] = []
        for await spawn in spawns { all.append(spawn) }
        return all
    }
}
