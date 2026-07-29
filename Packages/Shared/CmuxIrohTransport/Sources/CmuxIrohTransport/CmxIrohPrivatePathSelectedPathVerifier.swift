/// Confirms that a probe connection selected the exact supplied socket address.
struct CmxIrohPrivatePathSelectedPathVerifier: Sendable {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private static let settleInterval = Duration.milliseconds(100)
    private static let maximumSettleCount = 10

    private let sleep: Sleep

    /// Creates a verifier with injectable settling behavior.
    init(
        sleep: @escaping Sleep = { duration in
            // The bounded delay lets QUIC promote a direct hint over an initially selected relay.
            try await ContinuousClock().sleep(for: duration)
        }
    ) {
        self.sleep = sleep
    }

    /// Waits up to one second for the supplied socket address to become selected.
    func verify(
        connection: any CmxIrohConnectionPathInspecting,
        expectedRemoteAddress: String
    ) async throws {
        let normalizedExpected = Self.normalizedSocketAddress(expectedRemoteAddress)

        for settleCount in 0 ... Self.maximumSettleCount {
            let snapshots = await connection.connectionPathSnapshots()
            if snapshots.contains(where: {
                $0.isSelected
                    && $0.isIP
                    && !$0.isRelay
                    && Self.normalizedSocketAddress($0.remoteAddress) == normalizedExpected
            }) {
                return
            }
            guard settleCount < Self.maximumSettleCount else {
                throw CmxIrohPrivatePathProbeDialError.pathMismatch
            }
            try await sleep(Self.settleInterval)
        }
    }

    private static func normalizedSocketAddress(_ value: String) -> String {
        guard value.first == "[",
              let closingBracket = value.firstIndex(of: "]"),
              value.index(after: closingBracket) < value.endIndex,
              value[value.index(after: closingBracket)] == ":" else {
            return value
        }
        return String(value[value.index(after: value.startIndex) ..< closingBracket])
            + value[closingBracket...].dropFirst()
    }
}
