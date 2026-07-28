public import CmuxMobileShellModel

extension MobileShellComposite {
    /// Refines a device-keyed connection status to one exact pairing row.
    ///
    /// `macConnectionStatuses` is keyed by physical device id, but "Connected"
    /// is true of exactly one app instance at a time. A `.connected` device
    /// status therefore only applies to the row whose instance tag matches the
    /// connected pairing; the sibling build's row must not inherit it. Legacy
    /// rows without a tag keep the device-level status unchanged.
    public static func exactPairingConnectionStatus(
        deviceStatus: MobileMacConnectionStatus?,
        connectedMacDeviceID: String?,
        connectedMacInstanceTag: String?,
        rowMacDeviceID: String,
        rowInstanceTag: String?
    ) -> MobileMacConnectionStatus? {
        guard deviceStatus == .connected,
              connectedMacDeviceID == rowMacDeviceID,
              let rowInstanceTag,
              connectedMacInstanceTag != rowInstanceTag else {
            return deviceStatus
        }
        return nil
    }
}
