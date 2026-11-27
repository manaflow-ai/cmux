@testable import CmuxSudoBroker
import Foundation

struct RegistrationFailureSpawner: SudoProcessSpawning {
    let paths: SudoBrokerPaths
    let requestID: String
    let preserveResult: Bool

    func spawn(_ command: SudoExecutionCommand) throws -> SudoSpawnedProcess {
        let store = SudoSpoolStore(paths: paths)
        if preserveResult {
            _ = try store.settle(SudoResult(id: requestID, status: .denied))
        } else {
            try store.writeState(SudoRequestState(id: requestID, phase: .approved, updatedAt: .now))
        }
        // The inspector reports this synthetic generation as absent; cleanup can
        // exercise its result path without launching sudo or signalling a real PID.
        return SudoSpawnedProcess(
            identity: TestRunnerLauncher.defaultRunnerIdentity,
            processGroupIdentifier: 4_242,
            outputURL: store.outputURL(id: requestID),
            approvedScriptURL: nil,
            standardInput: nil,
            standardInputReadyMarker: nil,
            controlMarkers: SudoExecutionControlMarkers(),
            io: SudoSpawnedProcessIO(input: -1, output: -1, outputFile: -1)
        )
    }
}
