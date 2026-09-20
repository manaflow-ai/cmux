import CmuxMobileShellModel

/// The strongest connection failure claim the UI can make from the current
/// presence snapshot.
enum MobileMacConnectionFailureKind: Equatable {
    case knownOffline
    case generic

    static func resolve(
        connectionStatus: MobileMacConnectionStatus,
        presence: MobileMacPresenceSignal
    ) -> Self? {
        guard connectionStatus == .unavailable else { return nil }
        if presence == .offline {
            return .knownOffline
        }
        return .generic
    }
}

/// A value snapshot keeps presence classification independent from the
/// `DeviceTreePresence` source and safe to pass through the list boundary.
enum MobileMacPresenceSignal: Equatable {
    case online
    case offline
    case unknown
}
