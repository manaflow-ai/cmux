import Foundation

/// Transferred once to persistence; tests retain only the Sendable gate.
final class WorkstreamClearFileManager: FileManager {
    private let gate: WorkstreamClearGate

    init(gate: WorkstreamClearGate) {
        self.gate = gate
        super.init()
    }

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        gate.pauseIfArmed()
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}
