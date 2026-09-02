@testable import CmuxSudoBroker
import Foundation

struct TestRunnerBootstrapInspector: SudoProcessInspecting {
    private let parentProcessIdentifier: Int32
    private let parentExecutableURL: URL
    private let parentIdentity: SudoProcessIdentity

    init(parentProcessIdentifier: Int32, parentExecutableURL: URL) {
        self.parentProcessIdentifier = parentProcessIdentifier
        self.parentExecutableURL = parentExecutableURL
        parentIdentity = SudoProcessIdentity(
            processIdentifier: parentProcessIdentifier,
            startSeconds: 10,
            startMicroseconds: 20
        )
    }

    func identity(for processIdentifier: Int32) -> SudoProcessIdentity? {
        processIdentifier == parentProcessIdentifier ? parentIdentity : nil
    }

    func executableURL(for processIdentifier: Int32) -> URL? {
        processIdentifier == parentProcessIdentifier ? parentExecutableURL : nil
    }

    func arguments(for processIdentifier: Int32) -> [String]? { nil }

    func directChildProcessIdentifiers(of processIdentifier: Int32) -> [Int32] { [] }

    func processGroupIdentifier(for processIdentifier: Int32) -> Int32? { nil }

    func processIdentifiers(inProcessGroup processGroupIdentifier: Int32) -> [Int32]? { [] }

    func allProcessIdentifiers() -> [Int32] { [] }

    func isRunning(_ identity: SudoProcessIdentity) -> Bool { false }
}
