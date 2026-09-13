import Foundation
import os

/// Monotonic, privacy-safe startup timing for one Cloud terminal intent.
///
/// Stages are emitted at the owner boundaries that matter to the user: intent,
/// native allocation, resolution, attach, replay, first presented frame, and
/// input readiness. Unified-log timestamps plus `elapsed_ms` make warm and cold
/// distributions measurable without recording terminal contents or commands.
struct CloudTerminalStartupTrace: Sendable {
    private static let logger = Logger(subsystem: "com.cmuxterm.app", category: "CloudTerminalAttachment")

    let operationID: String
    let machineID: String
    let terminalID: String
    private let startedAt: UInt64

    init(machineID: String, terminalID: String) {
        operationID = UUID().uuidString.lowercased()
        self.machineID = machineID
        self.terminalID = terminalID
        startedAt = DispatchTime.now().uptimeNanoseconds
    }

    func mark(
        _ stage: String,
        surfaceID: UInt64? = nil,
        cursor: CloudVMCursor? = nil,
        outcome: String? = nil
    ) {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now >= startedAt ? (now - startedAt) / 1_000_000 : 0
        let surface = surfaceID.map(String.init) ?? "-"
        let generation = cursor?.generation ?? "-"
        let revision = cursor.map { String($0.revision) } ?? "-"
        let result = outcome ?? "-"
        Self.logger.info(
            "startup operation=\(operationID, privacy: .private(mask: .hash)) machine=\(machineID, privacy: .public) terminal=\(terminalID, privacy: .public) stage=\(stage, privacy: .public) elapsed_ms=\(elapsed) surface=\(surface) generation=\(generation, privacy: .private(mask: .hash)) revision=\(revision, privacy: .public) outcome=\(result, privacy: .public)"
        )
    }
}

