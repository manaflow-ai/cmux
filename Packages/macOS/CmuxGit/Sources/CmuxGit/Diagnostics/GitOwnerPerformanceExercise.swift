import Foundation

/// Behavioral result from the isolated Git ownership exercise.
///
/// Counter values are deliberately absent. Callers must cross-check the
/// process runtime metrics, whose values arise at the normal cache and scan
/// record sites.
public struct GitOwnerPerformanceExerciseResult: Sendable {
    public let requestCount: Int
    public let completedSnapshotCount: Int
    public let allSnapshotsMatched: Bool
    public let allWaitersRegistered: Bool
}

/// Runs the production tracked-status cache path against an isolated temporary
/// repository. It does not inspect user repositories or spawn a process.
public struct GitOwnerPerformanceExercise: Sendable {
    private let runtimeMetricsRecorder: CmuxGitRuntimeMetrics

    /// Creates an exercise that records through the production metrics owner.
    public init() {
        runtimeMetricsRecorder = GitMetadataService.runtimeMetrics
    }

    init(runtimeMetricsRecorder: CmuxGitRuntimeMetrics) {
        self.runtimeMetricsRecorder = runtimeMetricsRecorder
    }

    public func run(
        requestCount: Int
    ) async throws -> GitOwnerPerformanceExerciseResult {
        guard (2...8).contains(requestCount) else {
            throw GitOwnerPerformanceExerciseError.invalidRequestCount
        }
        let repositoryFixture = try GitOwnerPerformanceRepositoryFixture()
        let repository = try repositoryFixture.resolvedRepository()
        let gate = GitTrackedChangesSnapshotDiagnosticGate(expectedWaiterCount: requestCount)
        let scope = GitTrackedChangesSnapshotScope(
            runtimeMetricsRecorder: runtimeMetricsRecorder,
            diagnosticGate: gate
        )
        let identity = GitTrackedChangesRepositoryIdentity(repository: repository)
        let authority = await scope.authority(for: identity, fallbackRoundID: nil)
        let services = (0..<requestCount).map { _ in
            GitMetadataService(trackedChangesSnapshotScope: scope)
        }

        let snapshots = await withTaskGroup(of: GitTrackedChangesSnapshot.self) { group in
            for service in services {
                group.addTask {
                    await service.gitTrackedChangesSnapshot(
                        repository: repository,
                        snapshotRequest: .watcherEvent(authority)
                    )
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        let firstSnapshot = snapshots.first
        let allSnapshotsMatched = firstSnapshot.map { first in
            snapshots.allSatisfy { $0 == first }
        } ?? false
        return GitOwnerPerformanceExerciseResult(
            requestCount: requestCount,
            completedSnapshotCount: snapshots.count,
            allSnapshotsMatched: allSnapshotsMatched,
            allWaitersRegistered: gate.registeredWaiterCount == requestCount
        )
    }
}

enum GitOwnerPerformanceExerciseError: Error {
    case invalidRequestCount
    case repositoryResolutionFailed
}

/// Opt-in synchronization for the diagnostic cache only. Production cache
/// instances store literal `nil` and never allocate or lock this gate.
final class GitTrackedChangesSnapshotDiagnosticGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let expectedWaiterCount: Int
    private var storedRegisteredWaiterCount = 0

    init(expectedWaiterCount: Int) {
        self.expectedWaiterCount = expectedWaiterCount
    }

    var registeredWaiterCount: Int {
        condition.withLock { storedRegisteredWaiterCount }
    }

    func recordRegisteredWaiterCount(_ count: Int) {
        condition.withLock {
            storedRegisteredWaiterCount = max(storedRegisteredWaiterCount, count)
            condition.broadcast()
        }
    }

    func waitForExpectedWaiters() {
        let deadline = Date().addingTimeInterval(5)
        condition.lock()
        while storedRegisteredWaiterCount < expectedWaiterCount {
            guard condition.wait(until: deadline) else { break }
        }
        condition.unlock()
    }
}

private final class GitOwnerPerformanceRepositoryFixture {
    let root: URL
    private let gitDirectory: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-git-owner-proof-\(UUID().uuidString)", isDirectory: true)
        gitDirectory = root.appendingPathComponent(".git", isDirectory: true)
        let refs = gitDirectory.appendingPathComponent("refs/heads", isDirectory: true)
        try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(
            to: gitDirectory.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try "\(String(repeating: "f", count: 40))\n".write(
            to: refs.appendingPathComponent("main"),
            atomically: true,
            encoding: .utf8
        )
        try Self.emptyIndexData.write(to: gitDirectory.appendingPathComponent("index"))
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func resolvedRepository() throws -> ResolvedGitRepository {
        guard let repository = GitMetadataService.resolveGitRepository(containing: root.path) else {
            throw GitOwnerPerformanceExerciseError.repositoryResolutionFailed
        }
        return repository
    }

    private static let emptyIndexData = Data(
        Array("DIRC".utf8)
            + [0, 0, 0, 2]
            + [0, 0, 0, 0]
            + Array(repeating: 0, count: 20)
    )
}
