public import CmuxMobileShellModel
import Foundation

extension MobileShellComposite {
    /// Refines a device-keyed connection status to one exact pairing row.
    ///
    /// `macConnectionStatuses` is keyed by physical device id, but "Connected"
    /// is true of exactly one app instance at a time. A `.connected` device
    /// status therefore only applies to the row whose instance tag matches the
    /// connected pairing; a sibling build and a legacy untagged row must not
    /// inherit it.
    public static func exactPairingConnectionStatus(
        deviceStatus: MobileMacConnectionStatus?,
        connectedMacDeviceID: String?,
        connectedMacInstanceTag: String?,
        rowMacDeviceID: String,
        rowInstanceTag: String?
    ) -> MobileMacConnectionStatus? {
        guard connectedMacDeviceID == rowMacDeviceID else {
            return rowInstanceTag == nil ? deviceStatus : nil
        }
        let normalizedConnectedTag = connectedMacInstanceTag.flatMap {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let normalizedRowTag = rowInstanceTag.flatMap {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return normalizedConnectedTag == normalizedRowTag ? deviceStatus : nil
    }
}
