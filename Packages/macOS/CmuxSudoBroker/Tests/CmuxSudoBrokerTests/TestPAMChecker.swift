@testable import CmuxSudoBroker

struct TestPAMChecker: SudoPAMChecking {
    let enabled: Bool

    func touchIDIsEnabled() -> Bool { enabled }
}
