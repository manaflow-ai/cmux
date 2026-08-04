import Foundation

/// Runs one bounded Spotlight directory query while keeping the non-Sendable
/// `NSMetadataQuery` lifecycle confined to the main actor.
@MainActor
final class MobileTaskDirectoryMetadataQueryRunner {
    nonisolated enum QueryError: Error, Equatable {
        case unavailable
    }

    nonisolated struct Snapshot: Equatable, Sendable {
        let paths: [String]
        let gatheringComplete: Bool
        let totalMatchCount: Int
        let truncated: Bool
    }

    typealias DeadlineSleep = @MainActor @Sendable (Duration) async -> Void

    private let notificationCenter: NotificationCenter
    private let deadlineSleep: DeadlineSleep
    private var activeQuery: NSMetadataQuery?
    private var finishObserver: NSObjectProtocol?
    private var deadlineTask: Task<Void, Never>?
    private var gatheringContinuation: CheckedContinuation<Bool, Never>?
    private var queryDidStart = false

    init(
        notificationCenter: NotificationCenter = .default,
        deadlineSleep: DeadlineSleep? = nil
    ) {
        self.notificationCenter = notificationCenter
        self.deadlineSleep = deadlineSleep ?? { duration in
            try? await ContinuousClock().sleep(for: duration)
        }
    }

    func search(
        query rawQuery: String,
        maximumResults: Int,
        timeout: Duration
    ) async throws -> Snapshot {
        precondition(activeQuery == nil)
        precondition(maximumResults > 0)

        let query = NSMetadataQuery()
        query.searchScopes = [
            NSMetadataQueryLocalComputerScope,
            NSMetadataQueryNetworkScope,
        ]
        query.predicate = Self.makePredicate(query: rawQuery)
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemPathKey, ascending: true)]
        activeQuery = query

        let gatheringComplete = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gatheringContinuation = continuation
                finishObserver = notificationCenter.addObserver(
                    forName: .NSMetadataQueryDidFinishGathering,
                    object: query,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.finishGathering(complete: true)
                    }
                }

                queryDidStart = query.start()
                guard queryDidStart else {
                    finishGathering(complete: false)
                    return
                }
                deadlineTask = Task { @MainActor [weak self, deadlineSleep] in
                    await deadlineSleep(timeout)
                    guard !Task.isCancelled else { return }
                    self?.finishGathering(complete: false)
                }
                if Task.isCancelled {
                    cancelActiveQuery()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelActiveQuery()
            }
        }

        guard queryDidStart else {
            cleanup()
            throw QueryError.unavailable
        }
        guard !Task.isCancelled else {
            cleanup()
            throw CancellationError()
        }

        query.disableUpdates()
        let totalMatchCount = query.resultCount
        let resultLimit = min(totalMatchCount, maximumResults)
        var paths: [String] = []
        paths.reserveCapacity(resultLimit)
        var seen = Set<Data>()
        for index in 0..<resultLimit {
            guard !Task.isCancelled else {
                cleanup()
                throw CancellationError()
            }
            guard let path = query.value(
                ofAttribute: NSMetadataItemPathKey,
                forResultAt: index
            ) as? String,
                !path.isEmpty,
                seen.insert(Data(path.utf8)).inserted else {
                continue
            }
            paths.append(path)
        }
        let snapshot = Snapshot(
            paths: paths,
            gatheringComplete: gatheringComplete,
            totalMatchCount: totalMatchCount,
            truncated: totalMatchCount > resultLimit
        )
        cleanup()
        return snapshot
    }

    private func finishGathering(complete: Bool) {
        guard let continuation = gatheringContinuation else { return }
        gatheringContinuation = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        continuation.resume(returning: complete)
    }

    private func cancelActiveQuery() {
        finishGathering(complete: false)
        activeQuery?.stop()
    }

    private func cleanup() {
        deadlineTask?.cancel()
        deadlineTask = nil
        if let finishObserver {
            notificationCenter.removeObserver(finishObserver)
        }
        finishObserver = nil
        activeQuery?.stop()
        activeQuery = nil
        gatheringContinuation = nil
        queryDidStart = false
    }

    static func makePredicate(query: String) -> NSPredicate {
        let tokens = query
            .split { $0 == "/" || $0.isWhitespace }
            .prefix(8)
            .map(String.init)
        let directoryPredicate = NSPredicate(
            format: "ANY %K == %@",
            NSMetadataItemContentTypeTreeKey,
            "public.directory"
        )
        let tokenPredicates = tokens.map { token in
            NSCompoundPredicate(orPredicateWithSubpredicates: [
                NSPredicate(
                    format: "%K CONTAINS[cd] %@",
                    NSMetadataItemFSNameKey,
                    token
                ),
                NSPredicate(
                    format: "%K CONTAINS[cd] %@",
                    NSMetadataItemPathKey,
                    token
                ),
            ])
        }
        return NSCompoundPredicate(
            andPredicateWithSubpredicates: [directoryPredicate] + tokenPredicates
        )
    }
}
