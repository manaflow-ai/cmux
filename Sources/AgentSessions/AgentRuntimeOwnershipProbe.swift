import CmuxControlSocket
import CmuxSettings
import Darwin
import Foundation

/// Classifies persisted cmux runtime ownership without treating missing
/// process or socket evidence as proof that a foreign owner is dead.
struct AgentRuntimeOwnershipProbe: Sendable {
    static let defaultMaximumExternalProbes = 128

    enum Evidence: Equatable, Sendable {
        case current
        case provablyLiveForeign
        case provablyDeadForeign
        case unknownForeign
    }

    typealias CurrentSocketState = (
        activePath: String,
        pathOwnedByCurrentListener: Bool
    )
    typealias CurrentSocketStateResolver = @Sendable (String) -> CurrentSocketState
    typealias ProcessIdentityResolver = @Sendable (pid_t) -> AgentPIDProcessIdentity?

    private enum ComponentEvidence: Equatable, Sendable {
        case live
        case dead
        case unknown
    }

    private let environment: [String: String]
    private let currentSocketStateResolver: CurrentSocketStateResolver
    private let processIdentityResolver: ProcessIdentityResolver
    private let maximumExternalProbes: Int
    private let socketTransport = SocketTransport()
    private var currentSocketState: CurrentSocketState?
    private var socketEvidenceByPath: [String: SocketPathProbeResult] = [:]
    private var processIdentityByPID: [pid_t: AgentPIDProcessIdentity] = [:]
    private var processEvidenceByExpectedIdentity: [
        AgentPIDProcessIdentity: ComponentEvidence
    ] = [:]
    private var unavailableProcessEvidenceByPID: [pid_t: ComponentEvidence] = [:]
    private(set) var externalProbeCount = 0

    init(
        environment: [String: String],
        currentSocketStateResolver: @escaping CurrentSocketStateResolver,
        processIdentityResolver: @escaping ProcessIdentityResolver,
        maximumExternalProbes: Int = AgentRuntimeOwnershipProbe.defaultMaximumExternalProbes
    ) {
        self.environment = environment
        self.currentSocketStateResolver = currentSocketStateResolver
        self.processIdentityResolver = processIdentityResolver
        self.maximumExternalProbes = max(0, maximumExternalProbes)
    }

    mutating func evidence(for record: [String: Any]) -> Evidence {
        let currentRuntimeID = Self.normalized(environment["CMUX_RUNTIME_ID"])
        var runtimes: [[String: Any]] = []
        if let runtime = record["cmuxRuntime"] as? [String: Any] {
            runtimes.append(runtime)
        }
        if let activeRunID = Self.normalized(record["activeRunId"] as? String),
           let runs = record["runs"] as? [[String: Any]],
           let activeRun = runs.first(where: {
               Self.normalized($0["runId"] as? String) == activeRunID
           }),
           let runtime = activeRun["cmuxRuntime"] as? [String: Any] {
            runtimes.append(runtime)
        }

        var sawCurrentRuntime = false
        var sawForeignRuntime = false
        var sawDeadForeignRuntime = false
        var sawUnknownForeignRuntime = false
        for runtime in runtimes {
            if let runtimeID = Self.normalized(runtime["id"] as? String),
               runtimeID == currentRuntimeID {
                sawCurrentRuntime = true
                continue
            }
            sawForeignRuntime = true
            var runtimeHasDeadEvidence = false
            var runtimeHasUnknownEvidence = false

            if let expectedProcessIdentity = Self.processIdentity(runtime) {
                switch processEvidence(for: expectedProcessIdentity) {
                case .live:
                    return .provablyLiveForeign
                case .dead:
                    runtimeHasDeadEvidence = true
                case .unknown:
                    runtimeHasUnknownEvidence = true
                }
            }

            if let socketPath = Self.normalized(runtime["socketPath"] as? String) {
                if currentSocketState == nil {
                    let preferredSocketPath = SocketControlSettings.socketPath(
                        environment: environment,
                        bundleIdentifier: Self.normalized(environment["CMUX_BUNDLE_ID"])
                    )
                    currentSocketState = currentSocketStateResolver(preferredSocketPath)
                }
                if let currentSocketState,
                   currentSocketState.pathOwnedByCurrentListener,
                   SocketControlSettings.pathsMatch(
                       socketPath,
                       currentSocketState.activePath
                   ) {
                    // The current listener has replaced this persisted foreign endpoint.
                    runtimeHasDeadEvidence = true
                } else {
                    switch socketEvidence(at: socketPath) {
                    case .connected:
                        return .provablyLiveForeign
                    case .refused, .stale:
                        runtimeHasDeadEvidence = true
                    case .occupiedOrIndeterminate:
                        runtimeHasUnknownEvidence = true
                    }
                }
            }

            if runtimeHasUnknownEvidence || !runtimeHasDeadEvidence {
                sawUnknownForeignRuntime = true
            } else {
                sawDeadForeignRuntime = true
            }
        }

        if sawUnknownForeignRuntime { return .unknownForeign }
        if sawCurrentRuntime { return .current }
        if sawForeignRuntime, sawDeadForeignRuntime { return .provablyDeadForeign }
        return .unknownForeign
    }

    private mutating func processEvidence(
        for expectedIdentity: AgentPIDProcessIdentity
    ) -> ComponentEvidence {
        if let cached = processEvidenceByExpectedIdentity[expectedIdentity] {
            return cached
        }
        let pid = expectedIdentity.pid
        let evidence: ComponentEvidence
        if let currentIdentity = processIdentityByPID[pid] {
            evidence = currentIdentity == expectedIdentity ? .live : .dead
        } else if let unavailableEvidence = unavailableProcessEvidenceByPID[pid] {
            evidence = unavailableEvidence
        } else if reserveExternalProbe() {
            if let currentIdentity = processIdentityResolver(pid) {
                processIdentityByPID[pid] = currentIdentity
                evidence = currentIdentity == expectedIdentity ? .live : .dead
            } else {
                errno = 0
                let result = Darwin.kill(pid, 0)
                let resultError = errno
                if result != 0, resultError == ESRCH {
                    evidence = .dead
                } else {
                    // A successful existence probe, EPERM, and other failures
                    // prove neither death nor PID generation ownership.
                    evidence = .unknown
                }
                unavailableProcessEvidenceByPID[pid] = evidence
            }
        } else {
            evidence = .unknown
            unavailableProcessEvidenceByPID[pid] = evidence
        }
        processEvidenceByExpectedIdentity[expectedIdentity] = evidence
        return evidence
    }

    private mutating func socketEvidence(at path: String) -> SocketPathProbeResult {
        if let cached = socketEvidenceByPath[path] {
            return cached
        }
        let evidence: SocketPathProbeResult
        if reserveExternalProbe() {
            evidence = socketTransport.pathProbeResult(at: path)
        } else {
            evidence = .occupiedOrIndeterminate
        }
        socketEvidenceByPath[path] = evidence
        return evidence
    }

    private mutating func reserveExternalProbe() -> Bool {
        guard externalProbeCount < maximumExternalProbes else { return false }
        externalProbeCount += 1
        return true
    }

    private static func processIdentity(
        _ runtime: [String: Any]
    ) -> AgentPIDProcessIdentity? {
        guard let pidValue = (runtime["processId"] as? NSNumber)?.int64Value,
              pidValue > 0,
              pidValue <= Int64(Int32.max),
              let startSeconds = (runtime["processStartSeconds"] as? NSNumber)?.int64Value,
              startSeconds >= 0,
              let startMicroseconds = (runtime["processStartMicroseconds"] as? NSNumber)?.int64Value,
              startMicroseconds >= 0,
              startMicroseconds < 1_000_000 else {
            return nil
        }
        return AgentPIDProcessIdentity(
            pid: pid_t(pidValue),
            startSeconds: startSeconds,
            startMicroseconds: startMicroseconds
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
