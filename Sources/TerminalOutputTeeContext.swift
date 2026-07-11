import CmuxTerminalCore
import Foundation

/// Per-surface state owned by libghostty's serialized PTY read callback.
///
/// SAFETY: libghostty invokes a surface's tee callback serially on that
/// surface's IO read thread. After initialization, only that callback mutates
/// `detectors`; other threads receive copied value identifiers after a match.
final class TerminalOutputTeeContext: @unchecked Sendable {
    private struct DetectorBinding {
        let agentID: String
        var detector: PromptLineTurnDetector
    }

    let workspaceID: UUID
    let surfaceID: UUID
    private var detectors: [DetectorBinding]

    init(
        workspaceID: UUID,
        surfaceID: UUID,
        agentDefinitions: [CmuxTaskManagerCodingAgentDefinition]
    ) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.detectors = agentDefinitions.compactMap { definition in
            definition.promptTurnDetection.map {
                DetectorBinding(
                    agentID: definition.id,
                    detector: PromptLineTurnDetector(configuration: $0)
                )
            }
        }
    }

    func forEachCompletedAgentID(
        in bytes: UnsafeBufferPointer<UInt8>,
        _ body: (String) -> Void
    ) {
        for index in detectors.indices {
            let count = detectors[index].detector.consume(bytes)
            guard count > 0 else { continue }
            for _ in 0..<count {
                body(detectors[index].agentID)
            }
        }
    }
}
