enum RetiredStoredMacReconnectDemand: Equatable {
    case unresolvedTarget
    case macDeviceID(String)

    func targetsAny(_ macDeviceIDs: Set<String>) -> Bool {
        guard case .macDeviceID(let macDeviceID) = self else { return false }
        return macDeviceIDs.contains(macDeviceID)
    }
}
