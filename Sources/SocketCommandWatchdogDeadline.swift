struct SocketCommandWatchdogDeadline: Sendable {
    private let waitForNanoseconds: @Sendable (UInt64) async throws -> Void

    init(wait: @escaping @Sendable (UInt64) async throws -> Void = SocketCommandWatchdogDeadline.waitOnContinuousClock) {
        self.waitForNanoseconds = wait
    }

    func wait(nanoseconds: UInt64) async throws {
        try await waitForNanoseconds(nanoseconds)
    }

    private static func waitOnContinuousClock(nanoseconds: UInt64) async throws {
        let clampedNanoseconds = Int64(clamping: nanoseconds)
        try await ContinuousClock().sleep(for: .nanoseconds(clampedNanoseconds))
    }
}
