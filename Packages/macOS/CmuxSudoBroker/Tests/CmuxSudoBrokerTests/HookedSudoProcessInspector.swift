@testable import CmuxSudoBroker
import Foundation

/// Delegates to a real inspector while letting a test script the liveness answer.
final class HookedSudoProcessInspector: @unchecked Sendable, SudoProcessInspecting {
    private let base: any SudoProcessInspecting
    private let isRunningHook: @Sendable (SudoProcessIdentity) -> Bool

    init(
        base: any SudoProcessInspecting,
        isRunning: @Sendable @escaping (SudoProcessIdentity) -> Bool
    ) {
        self.base = base
        isRunningHook = isRunning
    }

    func identity(for processIdentifier: Int32) -> SudoProcessIdentity? {
        base.identity(for: processIdentifier)
    }

    func executableURL(for processIdentifier: Int32) -> URL? {
        base.executableURL(for: processIdentifier)
    }

    func arguments(for processIdentifier: Int32) -> [String]? {
        base.arguments(for: processIdentifier)
    }

    func directChildProcessIdentifiers(of processIdentifier: Int32) -> [Int32] {
        base.directChildProcessIdentifiers(of: processIdentifier)
    }

    func processGroupIdentifier(for processIdentifier: Int32) -> Int32? {
        base.processGroupIdentifier(for: processIdentifier)
    }

    func processIdentifiers(inProcessGroup processGroupIdentifier: Int32) -> [Int32]? {
        base.processIdentifiers(inProcessGroup: processGroupIdentifier)
    }

    func allProcessIdentifiers() -> [Int32] { base.allProcessIdentifiers() }

    func isRunning(_ identity: SudoProcessIdentity) -> Bool { isRunningHook(identity) }
}
