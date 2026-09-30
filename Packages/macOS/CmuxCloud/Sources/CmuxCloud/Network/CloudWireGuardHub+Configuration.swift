import CmuxAuthRuntime
import Foundation

extension CloudWireGuardHub {
    /// Configuration for the shared WireGuard hub lifecycle.
    public struct Configuration: Sendable {
        public init(
            enroll: @escaping @Sendable () async throws -> Enrollment,
            enrollWhenCloudDisabled: (@Sendable (AuthenticatedTeamScope?) async throws -> Enrollment)? = nil,
            refreshEnrollment: (@Sendable () async throws -> Enrollment)? = nil,
            clientURL: URL,
            socketURL: URL,
            spawner: any CloudWireGuardHubSpawning,
            waitUntilReady: @escaping @Sendable (_ socketPath: String) async throws -> Void,
            sleep: @escaping @Sendable (Duration) async throws -> Void,
            restartBackoff: [Duration],
            idleGrace: Duration,
            now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }
        ) {
            self.enroll = enroll
            self.enrollWhenCloudDisabled = enrollWhenCloudDisabled
            self.refreshEnrollment = refreshEnrollment
            self.clientURL = clientURL
            self.socketURL = socketURL
            self.spawner = spawner
            self.waitUntilReady = waitUntilReady
            self.sleep = sleep
            self.restartBackoff = restartBackoff
            self.idleGrace = idleGrace
            self.now = now
        }

        /// Enrolls the app tunnel identity with the control plane and writes
        /// the WireGuard config for the terminal role.
        public let enroll: @Sendable () async throws -> Enrollment
        /// Optional activation-only enrollment before the local marker commits.
        public let enrollWhenCloudDisabled: (@Sendable (AuthenticatedTeamScope?) async throws -> Enrollment)?
        public let refreshEnrollment: (@Sendable () async throws -> Enrollment)?
        /// The cmux-tui client binary that provides `wg hub`.
        public let clientURL: URL
        /// Where the hub's SOCKS5 unix socket lives; its parent is 0700.
        public let socketURL: URL
        public let spawner: any CloudWireGuardHubSpawning
        /// Resolves once `socketPath` accepts connections; throws on timeout.
        public let waitUntilReady: @Sendable (_ socketPath: String) async throws -> Void
        /// Cancellable delay used for restart backoff and idle shutdown.
        public let sleep: @Sendable (Duration) async throws -> Void
        /// Delays before each restart after an unexpected exit.
        public let restartBackoff: [Duration]
        /// How long the hub outlives its last lease.
        public let idleGrace: Duration
        public let now: @Sendable () -> ContinuousClock.Instant

        static let defaultRestartBackoff: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16)]
        static let defaultIdleGrace: Duration = .seconds(10)
    }
}
