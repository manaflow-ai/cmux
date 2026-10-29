@testable import CmuxSudoBroker
import Foundation

/// Accepts synthetic process signals without mutating the host process table.
struct TestSudoProcessSignaler: SudoProcessSignaling {
    func signal(processIdentifier: Int32, signal: Int32) -> Bool { true }

    func signal(processGroupIdentifier: Int32, signal: Int32) -> Bool { true }
}
