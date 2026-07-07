struct SocketCommandWatchdogDeadline: Sendable {
    private let waitForNanoseconds: @Sendable (UInt64) async throws -> Void

    init() {
        self.waitForNanoseconds = { nanoseconds in
            let clampedNanoseconds = Int64(clamping: nanoseconds)
            try await ContinuousClock().sleep(for: .nanoseconds(clampedNanoseconds))
        }
    }

    init(wait: @escaping @Sendable (UInt64) async throws -> Void) {
        self.waitForNanoseconds = wait
    }

    func wait(nanoseconds: UInt64) async throws {
        try await waitForNanoseconds(nanoseconds)
    }
}
