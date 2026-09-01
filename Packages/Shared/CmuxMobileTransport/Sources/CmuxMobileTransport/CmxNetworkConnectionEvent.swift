import Dispatch
@preconcurrency import Network

extension DispatchTimeInterval {
    static func milliseconds(coveringNanoseconds nanoseconds: UInt64) -> DispatchTimeInterval {
        let wholeMilliseconds = nanoseconds / 1_000_000
        let roundedMilliseconds = wholeMilliseconds + (nanoseconds % 1_000_000 == 0 ? 0 : 1)
        let milliseconds = max(1, roundedMilliseconds)
        return .milliseconds(Int(min(milliseconds, UInt64(Int.max))))
    }
}

enum CmxNetworkConnectionEvent: Sendable {
    case ready
    case waiting(String, CmxConnectFailureKind)
    case failed(String, CmxConnectFailureKind)
    case cancelled
    case other

    init(_ state: NWConnection.State) {
        switch state {
        case .ready:
            self = .ready
        case let .waiting(error):
            self = .waiting(error.cmxUserFacingDescription, error.cmxConnectFailureKind)
        case let .failed(error):
            self = .failed(error.cmxUserFacingDescription, error.cmxConnectFailureKind)
        case .cancelled:
            self = .cancelled
        case .setup, .preparing:
            self = .other
        @unknown default:
            self = .other
        }
    }
}

extension NWError {
    var cmxUserFacingDescription: String {
        switch self {
        case .dns:
            return "DNS lookup failed."
        case .posix:
            return "Network connection failed."
        case .tls:
            return "Secure connection failed."
        #if compiler(>=6.2)
        case .wifiAware:
            return "Network connection failed."
        #endif
        @unknown default:
            return "Network connection failed."
        }
    }

    var cmxConnectFailureKind: CmxConnectFailureKind {
        switch self {
        case let .posix(code):
            switch code {
            case .ECONNREFUSED:
                return .connectionRefused
            case .EHOSTUNREACH, .ENETUNREACH, .ENETDOWN, .EHOSTDOWN, .ENETRESET, .ECONNABORTED:
                return .hostUnreachable
            case .ETIMEDOUT:
                return .timedOut
            case .EPERM, .EACCES:
                return .permissionDenied
            default:
                return .generic
            }
        case .dns:
            return .dnsFailed
        case .tls:
            return .secureChannelFailed
        default:
            return .generic
        }
    }
}

extension CmxNetworkByteTransport {
    func waitingKindFailsConnect(_ kind: CmxConnectFailureKind) -> Bool {
        switch kind {
        case .connectionRefused:
            return true
        case .hostUnreachable, .dnsFailed, .permissionDenied,
             .secureChannelFailed, .timedOut, .generic:
            return false
        }
    }
}
