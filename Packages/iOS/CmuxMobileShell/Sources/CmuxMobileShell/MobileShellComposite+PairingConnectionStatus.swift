public import CmuxMobileShellModel

extension MobileShellComposite {
    /// Refines a device-keyed connection status to one exact pairing row.
    ///
    /// `macConnectionStatuses` is keyed by physical device id, but a live or
    /// in-flight connection belongs to exactly one app instance at a time.
    /// Any device status (connected, reconnecting, …) therefore only applies
    /// to the row whose instance tag matches the connection's pairing; a
    /// sibling build's row must not inherit it. When either tag is unknown
    /// (legacy rows, or a dial with no pinned target) the device-level status
    /// passes through unchanged.
    public static func exactPairingConnectionStatus(
        deviceStatus: MobileMacConnectionStatus?,
        connectedMacDeviceID: String?,
        connectedMacInstanceTag: String?,
        rowMacDeviceID: String,
        rowInstanceTag: String?
    ) -> MobileMacConnectionStatus? {
        guard deviceStatus != nil,
              connectedMacDeviceID == rowMacDeviceID,
              let rowInstanceTag else {
            return deviceStatus
        }
        if deviceStatus == .connected {
            // Connected is true of exactly one pairing; an unknown connection
            // tag must not light a tagged sibling's row.
            return connectedMacInstanceTag == rowInstanceTag ? deviceStatus : nil
        }
        // Reconnecting/unavailable with a known target pairing belongs to that
        // pairing only; with no known target the device status passes through.
        if let connectedMacInstanceTag, connectedMacInstanceTag != rowInstanceTag {
            return nil
        }
        return deviceStatus
    }
}
