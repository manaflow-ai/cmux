import CmuxTerminal
import CmuxTerminalCore
import Foundation

/// Captures generation-checked foreground identity and live-bottom terminal evidence.
@MainActor
final class AgentTerminalStateSurfaceObserver {
    let workspaceID: UUID
    let surfaceID: UUID
    let expectedRuntimeGeneration: UInt64
    private let inspector: AgentTerminalProcessInspector
    private let classifier: AgentTerminalStateClassifier
    private var previousReliableState: AgentTerminalSemanticState?
    private var previousReliableIdentity: AgentTerminalProcessIdentity?
    private var recognitionCache = AgentTerminalRecognitionCache()

    init(
        workspaceID: UUID,
        surfaceID: UUID,
        expectedRuntimeGeneration: UInt64,
        inspector: AgentTerminalProcessInspector = .init(),
        classifier: AgentTerminalStateClassifier = .init()
    ) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.expectedRuntimeGeneration = expectedRuntimeGeneration
        self.inspector = inspector
        self.classifier = classifier
    }

    func capture() async -> AgentTerminalScreenSnapshot? {
        guard let surface = GhosttyApp.terminalSurfaceRegistry.terminalSurface(id: surfaceID),
              surface.runtimeSurfaceGeneration == expectedRuntimeGeneration,
              let rawPID = surface.foregroundProcessID() else { return nil }
        let pid = Int32(rawPID)
        let runtimeGeneration = expectedRuntimeGeneration
        guard let identity = await inspector.identity(pid: pid, runtimeGeneration: runtimeGeneration) else { return nil }
        let familyID: String?
        if !recognitionCache.requiresSnapshot(for: identity) {
            familyID = recognitionCache.familyID(for: identity)
        } else {
            guard let process = await inspector.snapshot(pid: pid, runtimeGeneration: runtimeGeneration),
                  process.identity == identity else { return nil }
            familyID = classifier.recognize(process)?.id
            recognitionCache.store(identity: identity, familyID: familyID)
            previousReliableIdentity = nil
            previousReliableState = nil
        }
        guard surface.runtimeSurfaceGeneration == runtimeGeneration,
              surface.foregroundProcessID() == rawPID else { return nil }
        guard let gridRows = surface.rawSizingSample()?.rows, gridRows > 0 else { return nil }
        guard let liveBottom = await surface.boundedActiveScreenTailText(
            maxRows: 48,
            maxBytes: 48 * 1024
        ) else { return nil }
        guard surface.runtimeSurfaceGeneration == runtimeGeneration,
              surface.foregroundProcessID() == rawPID,
              surface.rawSizingSample()?.rows == gridRows else { return nil }
        let identityAfterCapture = await inspector.identity(pid: pid, runtimeGeneration: runtimeGeneration)
        guard identityAfterCapture == identity,
              surface.runtimeSurfaceGeneration == runtimeGeneration,
              surface.foregroundProcessID() == rawPID else { return nil }
        return AgentTerminalScreenSnapshot(
            processIdentity: identity,
            familyID: familyID,
            liveBottomText: liveBottom,
            previousReliableState: previousReliableIdentity == identity ? previousReliableState : nil
        )
    }

    func recordPublished(_ classification: AgentTerminalStateClassification) {
        guard classification.familyID != nil, classification.state != .unknown else {
            previousReliableIdentity = nil
            previousReliableState = nil
            return
        }
        previousReliableIdentity = classification.processIdentity
        previousReliableState = classification.state
    }
}
