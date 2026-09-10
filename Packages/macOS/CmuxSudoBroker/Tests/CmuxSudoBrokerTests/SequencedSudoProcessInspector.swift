@testable import CmuxSudoBroker
import Foundation
import os

/// Provides deterministic synchronous identity changes for PID-reuse regression coverage.
final class SequencedSudoProcessInspector: @unchecked Sendable, SudoProcessInspecting {
    private let processIdentifier: Int32
    private let identities: OSAllocatedUnfairLock<[SudoProcessIdentity]>
    private let processArguments: [String]

    init(
        processIdentifier: Int32,
        identities: [SudoProcessIdentity],
        arguments: [String]
    ) {
        self.processIdentifier = processIdentifier
        self.identities = OSAllocatedUnfairLock(initialState: identities)
        processArguments = arguments
    }

    func identity(for processIdentifier: Int32) -> SudoProcessIdentity? {
        guard processIdentifier == self.processIdentifier else { return nil }
        // This short lock only sequences calls through a synchronous process-inspection seam.
        return identities.withLock { identities in
            guard !identities.isEmpty else { return nil }
            return identities.removeFirst()
        }
    }

    func executableURL(for processIdentifier: Int32) -> URL? { nil }

    func arguments(for processIdentifier: Int32) -> [String]? {
        processIdentifier == self.processIdentifier ? processArguments : nil
    }

    func directChildProcessIdentifiers(of processIdentifier: Int32) -> [Int32] { [] }

    func processGroupIdentifier(for processIdentifier: Int32) -> Int32? { nil }

    func processIdentifiers(inProcessGroup processGroupIdentifier: Int32) -> [Int32]? { [] }

    func allProcessIdentifiers() -> [Int32] { [processIdentifier] }

    func isRunning(_ identity: SudoProcessIdentity) -> Bool { false }
}
