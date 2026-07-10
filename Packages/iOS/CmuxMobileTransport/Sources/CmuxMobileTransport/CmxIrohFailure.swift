public import Foundation

/// A classified error returned by the cmux iroh C FFI.
public struct CmxIrohFailure: Error, Equatable, Sendable {
    /// The raw FFI error kind.
    public var kind: CmxIrohErrorKind
    /// Human-readable detail supplied by the FFI.
    public var message: String

    /// Creates an iroh FFI failure.
    public init(kind: CmxIrohErrorKind, message: String) {
        self.kind = kind
        self.message = message
    }
}

/// Stable iroh C FFI error-kind codes.
public enum CmxIrohErrorKind: UInt32, Sendable, Equatable {
    case none = 0
    case invalidArgument = 1
    case timedOut = 2
    case connectionRefused = 3
    case hostUnreachable = 4
    case permissionDenied = 5
    case dnsFailed = 6
    case secureChannelFailed = 7
    case endpointClosed = 8
    case notConnected = 9
    case io = 10
    case internalFailure = 11
    case unknown = 0xffff_ffff

    /// The matching generic connect-failure classification used by the shell UI.
    public var connectFailureKind: CmxConnectFailureKind {
        switch self {
        case .timedOut:
            return .timedOut
        case .connectionRefused:
            return .connectionRefused
        case .hostUnreachable, .endpointClosed, .notConnected:
            return .hostUnreachable
        case .permissionDenied:
            return .permissionDenied
        case .dnsFailed:
            return .dnsFailed
        case .secureChannelFailed:
            return .secureChannelFailed
        case .none, .invalidArgument, .io, .internalFailure, .unknown:
            return .generic
        }
    }

    /// Creates a known kind, or ``unknown`` for future FFI codes.
    public init(rawFFIValue: UInt32) {
        self = Self(rawValue: rawFFIValue) ?? .unknown
    }
}
