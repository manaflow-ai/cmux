struct SimulatorSubprocessResult: Sendable {
    let status: Int32
    let standardOutput: String
    let standardError: String
    let outputWasTruncated: Bool
    let errorWasTruncated: Bool
    let timedOut: Bool

    init(
        status: Int32,
        standardOutput: String,
        standardError: String,
        outputWasTruncated: Bool = false,
        errorWasTruncated: Bool = false,
        timedOut: Bool = false
    ) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.outputWasTruncated = outputWasTruncated
        self.errorWasTruncated = errorWasTruncated
        self.timedOut = timedOut
    }
}
