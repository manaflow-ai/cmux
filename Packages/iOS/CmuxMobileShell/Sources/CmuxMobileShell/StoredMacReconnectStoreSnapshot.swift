import CmuxMobilePairedMac

enum StoredMacReconnectStoreSnapshot: Sendable {
    case loaded(
        request: StoredMacReconnectStoreRequest,
        activeMac: MobilePairedMac?,
        allMacs: [MobilePairedMac]
    )
    case failed(request: StoredMacReconnectStoreRequest, errorDescription: String)

    var request: StoredMacReconnectStoreRequest {
        switch self {
        case .loaded(let request, _, _), .failed(let request, _):
            request
        }
    }
}
