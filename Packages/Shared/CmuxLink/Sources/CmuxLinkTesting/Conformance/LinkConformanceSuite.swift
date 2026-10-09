import CmuxLink

/// The carrier conformance suite (a3-link.md section 8). Every carrier lane
/// runs it against its own transport:
///
/// ```swift
/// @Test(arguments: ConformanceCase.allCases)
/// func conformance(_ testCase: ConformanceCase) async throws {
///     let outcome = try await LinkConformanceSuite(harness: WebRTCHarness()).run(testCase)
///     #expect(outcome == .passed)
/// }
/// ```
public struct LinkConformanceSuite: Sendable {
    public let harness: any ConformanceHarness
    public var configuration: LinkConfiguration
    public var policy: PathPolicy
    /// Real-time limit for each step of a case.
    public var stepTimeout: Duration
    /// `rawBackPressure`: the most bytes a sender may get accepted while the
    /// receiving consumer reads nothing (both ends' queues, libraries and
    /// kernel socket buffers together).
    public var rawBufferLimitBytes: Int = 24 << 20

    public init(
        harness: any ConformanceHarness,
        configuration: LinkConfiguration = LinkConfiguration(
            handshakeTimeout: .seconds(2),
            backoff: Backoff(initial: .milliseconds(5), maximum: .milliseconds(100)),
            maxConnectAttempts: 100,
            resumeWindow: .seconds(30),
            degradedRTT: nil
        ),
        policy: PathPolicy = PathPolicy(preferenceWindow: .milliseconds(20), upgradeRetry: nil),
        stepTimeout: Duration = .seconds(10)
    ) {
        self.harness = harness
        self.configuration = configuration
        self.policy = policy
        self.stepTimeout = stepTimeout
    }

    public func run(_ testCase: ConformanceCase) async throws -> ConformanceOutcome {
        let deadline = Deadline(limit: stepTimeout, harness: harness.name, testCase: testCase)
        if testCase == .rawBackPressure {
            do {
                let outcome = try await rawBackPressure(deadline: deadline)
                await harness.tearDown()
                return outcome
            } catch {
                await harness.tearDown()
                throw error
            }
        }
        let fixture = try await ConformanceFixture(
            harness: harness, configuration: configuration, policy: policy, deadline: deadline
        )
        do {
            let outcome = try await body(of: testCase)(fixture)
            await fixture.shutdown()
            await harness.tearDown()
            return outcome
        } catch {
            await fixture.shutdown()
            await harness.tearDown()
            throw error
        }
    }

    public func runAll() async throws -> [ConformanceCase: ConformanceOutcome] {
        var outcomes: [ConformanceCase: ConformanceOutcome] = [:]
        for testCase in ConformanceCase.allCases {
            outcomes[testCase] = try await run(testCase)
        }
        return outcomes
    }

    private func body(of testCase: ConformanceCase) -> @Sendable (ConformanceFixture) async throws -> ConformanceOutcome {
        switch testCase {
        case .ordering: ordering
        case .lossRecovery: lossRecovery
        case .reconnectResume: reconnectResume
        case .backPressure: backPressure
        case .closeSemantics: closeSemantics
        case .pathChangeMidStream: pathChangeMidStream
        case .priority: priority
        case .rawBackPressure: { _ in .skipped("runs without a session fixture") }
        }
    }
}
