public import Foundation
import CmuxNextCompat

/// One step of a legacy Cloud link's start (``CloudMachineLink``): each has a deadline and a
/// log line, so a start that does not come up says where it stopped and why.
public enum CloudLinkStep: String, Sendable, Hashable, CaseIterable {
    /// `POST /api/vm/{id}/attach-endpoint`.
    case attachEndpoint = "attach-endpoint"
    /// This Mac's WireGuard hub (`POST /api/vm/tunnel`, then `cmux-tui wg hub`).
    case hub
    /// `POST /api/vm/{id}/cmux-remote/approve` for a new enrollment.
    case approve
    /// `cmux-tui remote connect` until its first `connected` line.
    case remoteConnect = "remote-connect"

    /// How long the step may take. A deadline is the step's own calls' bounds plus slack, so it
    /// only fires on work that stopped answering (attach 30 s, enroll 60 s + hub 45 s, approve
    /// 60 s, the link's first line 60 s).
    public var deadline: Duration {
        switch self {
        case .attachEndpoint: .seconds(45)
        case .hub: .seconds(120)
        case .approve: .seconds(75)
        case .remoteConnect: .seconds(75)
        }
    }

    /// What the step does, in the words a failure shows.
    public var text: String {
        switch self {
        case .attachEndpoint: "asking cmux Cloud for the machine's address"
        case .hub: "starting this Mac's tunnel to cmux Cloud"
        case .approve: "approving this Mac on the machine"
        case .remoteConnect: "opening the link to the machine"
        }
    }
}

/// A legacy link start that stopped at ``step``: the step's own error, or its deadline.
public struct CloudLinkStartError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    public let step: CloudLinkStep
    public let reason: String
    /// No retry of the same start can help (a refusal the server or this Mac gave: signed out,
    /// a plan, a 4xx other than a conflict or rate limit, a missing `cmux-tui`). A deadline or a
    /// transport error is not: the machine may still be booting.
    public let definitive: Bool
    public let timedOut: Bool

    public init(step: CloudLinkStep, reason: String, definitive: Bool = false, timedOut: Bool = false) {
        self.step = step
        self.reason = reason
        self.definitive = definitive
        self.timedOut = timedOut
    }

    /// `error` from `step`, classified.
    public init(step: CloudLinkStep, error: any Error) {
        if let already = error as? CloudLinkStartError {
            self = already
            return
        }
        self.init(step: step, reason: Self.reason(error), definitive: Self.isDefinitive(error))
    }

    /// The step's deadline passed.
    public static func deadline(_ step: CloudLinkStep) -> CloudLinkStartError {
        CloudLinkStartError(step: step, reason: "no answer in \(step.deadline.components.seconds) s", timedOut: true)
    }

    public var description: String { "Couldn't connect while \(step.text): \(reason)" }
    public var errorDescription: String? { description }

    static func reason(_ error: any Error) -> String {
        if let api = error as? CloudAPIError { return api.text() }
        if let localized = (error as? any LocalizedError)?.errorDescription { return localized }
        return String(describing: error)
    }

    static func isDefinitive(_ error: any Error) -> Bool {
        switch error {
        case let api as CloudAPIError:
            switch api {
            case .notSignedIn, .planRequired, .noBackend: return true
            case .http(let status, _, _, _, _): return (400..<500).contains(status) && ![408, 409, 423, 425, 429].contains(status)
            case .timedOut, .transport, .decoding: return false
            }
        case let child as ChildProcessError:
            if case .missingBinary = child { return true }
            return false
        case is CloudTunnelHub.HubError:
            return true
        default:
            return false
        }
    }
}

/// Where a legacy link's start is, for the app's failure text and its wait (``CloudMachineLink/progress``):
/// the step running now and when it began, and the last start's failure. Read from any thread.
public nonisolated final class CloudLinkProgress: Sendable {
    public struct Snapshot: Sendable, Equatable {
        public var step: CloudLinkStep?
        public var since: ContinuousClock.Instant?
        public var failure: CloudLinkStartError?
    }

    private let state = Mutex(Snapshot())

    init() {}

    public var snapshot: Snapshot { state.withLock { $0 } }

    func began(_ step: CloudLinkStep) {
        state.withLock { $0.step = step; $0.since = .now }
    }

    /// The start came up: no step runs and no failure stands.
    func succeeded() {
        state.withLock { $0 = Snapshot() }
    }

    func failed(_ failure: CloudLinkStartError) {
        state.withLock { $0.step = nil; $0.since = nil; $0.failure = failure }
    }

    /// The start ended for another reason (a pause, a stop): its step no longer runs.
    func ended() {
        state.withLock { $0.step = nil; $0.since = nil }
    }
}

/// Runs one link step under its deadline. The bound holds even when the work ignores
/// cancellation: the caller is answered at the bound and the work is cancelled, never awaited
/// (``SandboxDeadline``), so a step that stopped answering can never hold the start forever.
func runLinkStep<T: Sendable>(_ step: CloudLinkStep, within bound: Duration? = nil,
                              _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    do {
        return try await SandboxDeadline.race(bound ?? step.deadline, timeout: { CloudLinkStartError.deadline(step) }, work)
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        throw CloudLinkStartError(step: step, error: error)
    }
}
