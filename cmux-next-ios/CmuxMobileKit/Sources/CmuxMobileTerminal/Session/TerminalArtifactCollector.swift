import CmuxMobileArtifacts
import Foundation

/// Files and links found in a terminal's output, collected off the main
/// thread. The extractor's regex scan costs time per byte; under an output
/// flood it was the largest main-thread cost after rendering. Scans and
/// screen reconciles run in order on one serial queue that owns the
/// extractor and the list; each change is published to the main actor as a
/// whole list, in order.
public final class TerminalArtifactCollector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cmuxMobile.terminal.artifacts", qos: .utility)
    /// Touched only on `queue`.
    private var extractor = ArtifactExtractor()
    private var list: [TerminalArtifact] = []
    private let publish: @Sendable ([TerminalArtifact]) -> Void

    /// `publish` is called on the main queue with the whole list after each change.
    public init(publish: @escaping @MainActor ([TerminalArtifact]) -> Void) {
        self.publish = { list in DispatchQueue.main.async { MainActor.assumeIsolated { publish(list) } } }
    }

    /// Scans a batch of output (in the order batches are given).
    public func scan(_ data: Data) {
        queue.async { [self] in
            let found = extractor.scan(data)
            guard !found.isEmpty else { return }
            list = ArtifactExtractor.droppingFragments(list + found)
            publish(list)
        }
    }

    /// Rescans the screen's text against the list (see `ArtifactExtractor.reconcile`).
    public func reconcile(screenText: String, columns: Int?) {
        queue.async { [self] in
            let merged = ArtifactExtractor.droppingFragments(extractor.reconcile(list, screenText: screenText, columns: columns))
            guard merged != list else { return }
            list = merged
            publish(list)
        }
    }

    /// Waits until everything given so far was scanned (and published to the main queue).
    public func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { DispatchQueue.main.async { continuation.resume() } }
        }
    }
}
