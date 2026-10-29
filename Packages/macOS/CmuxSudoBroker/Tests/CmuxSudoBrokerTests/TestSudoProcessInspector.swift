@testable import CmuxSudoBroker
import Foundation

struct TestSudoProcessInspector: SudoProcessInspecting {
    private let runningIdentities: Set<SudoProcessIdentity>

    init(
        runningIdentities: Set<SudoProcessIdentity> = [SudoTestFixture.defaultRequesterIdentity]
    ) {
        self.runningIdentities = runningIdentities
    }

    func identity(for processIdentifier: Int32) -> SudoProcessIdentity? {
        runningIdentities.first { $0.processIdentifier == processIdentifier }
    }

    func executableURL(for processIdentifier: Int32) -> URL? { nil }

    func arguments(for processIdentifier: Int32) -> [String]? { nil }

    func directChildProcessIdentifiers(of processIdentifier: Int32) -> [Int32] { [] }

    func processGroupIdentifier(for processIdentifier: Int32) -> Int32? { nil }

    func processIdentifiers(inProcessGroup processGroupIdentifier: Int32) -> [Int32]? { [] }

    func allProcessIdentifiers() -> [Int32] {
        runningIdentities.map(\.processIdentifier)
    }

    func isRunning(_ identity: SudoProcessIdentity) -> Bool {
        runningIdentities.contains(identity)
    }
}
