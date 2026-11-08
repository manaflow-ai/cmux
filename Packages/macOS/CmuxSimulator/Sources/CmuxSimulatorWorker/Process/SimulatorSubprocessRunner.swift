import CmuxSimulator
import Foundation

struct SimulatorSubprocessRunner: Sendable {
    private let terminationGrace: Duration
    private let timeout: Duration
    private let standardOutputLimit: Int
    private let standardErrorLimit: Int
    private let sleeper: any SimulatorSubprocessSleeping

    init(
        terminationGrace: Duration = .seconds(1),
        timeout: Duration = .seconds(120),
        standardOutputLimit: Int = 8 * 1_024 * 1_024,
        standardErrorLimit: Int = 2 * 1_024 * 1_024,
        sleeper: any SimulatorSubprocessSleeping = ContinuousSimulatorSubprocessSleeper()
    ) {
        self.terminationGrace = terminationGrace
        self.timeout = timeout
        self.standardOutputLimit = standardOutputLimit
        self.standardErrorLimit = standardErrorLimit
        self.sleeper = sleeper
    }

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:]
    ) async throws -> SimulatorSubprocessResult {
        guard standardOutputLimit >= 0, standardErrorLimit >= 0 else {
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                String(
                    localized: "simulator.failure.commandOutputLimit",
                    defaultValue: "Simulator subprocess output limits must be nonnegative."
                )
            )
        }
        let standardOutput = Pipe()
        let standardError = Pipe()
        let box = SimulatorSubprocessBox(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            standardOutput: standardOutput,
            standardError: standardError,
            terminationGrace: terminationGrace,
            timeout: timeout,
            standardOutputLimit: standardOutputLimit,
            standardErrorLimit: standardErrorLimit,
            sleeper: sleeper
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task { await box.start(continuation: continuation) }
            }
        } onCancel: {
            Task { await box.cancel() }
        }
    }
}
