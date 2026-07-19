import CmuxTerminalCore
import Foundation

/// Serializes bounded screen classification and reuses results for unchanged snapshots.
actor AgentTerminalClassificationWorker {
    private let classifier: AgentTerminalStateClassifier
    private var cachedSnapshots: [UUID: AgentTerminalScreenSnapshot] = [:]
    private var cachedResults: [UUID: AgentTerminalStateClassification] = [:]

    init(classifier: AgentTerminalStateClassifier = .init()) {
        self.classifier = classifier
    }

    func classify(surfaceID: UUID, snapshot: AgentTerminalScreenSnapshot) -> AgentTerminalStateClassification {
        if cachedSnapshots[surfaceID] == snapshot, let cached = cachedResults[surfaceID] { return cached }
        let result = classifier.classify(snapshot)
        cachedSnapshots[surfaceID] = snapshot
        cachedResults[surfaceID] = result
        return result
    }

    func remove(surfaceID: UUID) {
        cachedSnapshots[surfaceID] = nil
        cachedResults[surfaceID] = nil
    }
}
