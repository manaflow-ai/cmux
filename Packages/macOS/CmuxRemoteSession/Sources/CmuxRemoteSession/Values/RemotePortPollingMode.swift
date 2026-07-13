internal import Foundation

/// Which fallback polling strategy the port scanner uses when TTY-scoped
/// scans are not (yet) possible, with the legacy cadence pinned per mode.
/// Lifted one-for-one from the legacy controller's nested enum.
enum RemotePortPollingMode {
    case hostWide
    case hostWideDelta
    case ttyScoped

    var initialDelay: TimeInterval {
        switch self {
        case .hostWide:
            return 0.5
        case .hostWideDelta:
            return 0.5
        case .ttyScoped:
            return 1.0
        }
    }

    var repeatInterval: TimeInterval {
        switch self {
        case .hostWide:
            return 2.0
        case .hostWideDelta:
            return 5.0
        case .ttyScoped:
            return 5.0
        }
    }
}
