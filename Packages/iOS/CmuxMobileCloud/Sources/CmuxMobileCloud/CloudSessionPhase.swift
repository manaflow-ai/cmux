public import Foundation

/// The tunnel's lifecycle as the Cloud section sees it.
public enum CloudTunnelPhase: Sendable, Equatable {
    /// The section is not on screen; no tunnel.
    case idle
    /// Enrolling with the control plane and starting the tunnel.
    case starting
    /// The tunnel is up; `fingerprint` names this device on the network.
    case ready(fingerprint: String)
    /// Enrollment or start failed.
    case failed(CloudSessionFailure)
}

/// A loadable list's lifecycle.
public enum CloudListPhase<Element: Sendable & Equatable>: Sendable, Equatable {
    /// Never loaded.
    case idle
    /// A load is in flight; `previous` keeps the last rows on screen.
    case loading(previous: [Element])
    /// Loaded rows.
    case loaded([Element])
    /// The load failed; `previous` keeps the last rows on screen.
    case failed(CloudSessionFailure, previous: [Element])

    /// The rows to render regardless of phase.
    public var elements: [Element] {
        switch self {
        case .idle: return []
        case .loading(let previous), .failed(_, let previous): return previous
        case .loaded(let elements): return elements
        }
    }

    /// Whether a load is in flight.
    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

/// A user-presentable failure, classified so the UI can pick copy.
public struct CloudSessionFailure: Error, Sendable, Equatable {
    /// Which copy the UI shows.
    public enum Kind: Sendable, Equatable {
        /// The Stack session is missing or rejected.
        case signedOut
        /// The control plane refused the call with an HTTP status.
        case controlPlane(status: Int)
        /// The tunnel could not be enrolled or started.
        case tunnel
        /// The daemon could not be reached or refused the link.
        case link
        /// The device identity store is locked or unwritable.
        case identity
        /// Anything else.
        case other
    }

    /// The classification.
    public var kind: Kind
    /// The underlying error's description, for diagnostics.
    public var detail: String

    /// Creates a failure.
    public init(kind: Kind, detail: String) {
        self.kind = kind
        self.detail = detail
    }

    /// Classifies an arbitrary error thrown during `stage`.
    public static func classify(_ error: any Error, stage: Stage) -> CloudSessionFailure {
        if let api = error as? CloudAPIError {
            switch api {
            case .notSignedIn: return CloudSessionFailure(kind: .signedOut, detail: "not signed in")
            case .httpStatus(let status, let message):
                if status == 401 { return CloudSessionFailure(kind: .signedOut, detail: message ?? "401") }
                return CloudSessionFailure(kind: .controlPlane(status: status), detail: message ?? "HTTP \(status)")
            case .invalidURL(let detail), .malformedResponse(let detail):
                return CloudSessionFailure(kind: .other, detail: detail)
            }
        }
        if error is CloudDeviceIdentityResolver.Failure {
            return CloudSessionFailure(kind: .identity, detail: String(describing: error))
        }
        switch stage {
        case .tunnel: return CloudSessionFailure(kind: .tunnel, detail: String(describing: error))
        case .link: return CloudSessionFailure(kind: .link, detail: String(describing: error))
        case .list: return CloudSessionFailure(kind: .other, detail: String(describing: error))
        }
    }

    /// Where an error happened, for classification of non-API errors.
    public enum Stage: Sendable {
        case tunnel
        case link
        case list
    }
}
