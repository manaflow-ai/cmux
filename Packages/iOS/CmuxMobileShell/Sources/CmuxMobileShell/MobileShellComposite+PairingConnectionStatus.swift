import CMUXMobileCore
public import CmuxMobileShellModel
import Foundation

extension MobileShellComposite {
    /// Refines a device-keyed connection status to one exact pairing row.
    ///
    /// `macConnectionStatuses` is keyed by physical device id, but "Connected"
    /// is true of exactly one app instance at a time. Only that ambiguous
    /// status needs build-scoped refinement; all other statuses already belong
    /// to the device row and must remain visible while it reconnects or is
    /// unavailable.
    public static func exactPairingConnectionStatus(
        deviceStatus: MobileMacConnectionStatus?,
        connectedMacDeviceID: String?,
        connectedMacInstanceTag: String?,
        rowMacDeviceID: String,
        rowInstanceTag: String?
    ) -> MobileMacConnectionStatus? {
        guard deviceStatus == .connected else { return deviceStatus }

        let canonicalRowDeviceID = CmxMacAppInstanceIdentity(
            macDeviceID: rowMacDeviceID,
            instanceTag: nil
        ).macDeviceID
        let canonicalConnectedDeviceID = connectedMacDeviceID.map {
            CmxMacAppInstanceIdentity(macDeviceID: $0, instanceTag: nil).macDeviceID
        }
        guard canonicalConnectedDeviceID == canonicalRowDeviceID else { return nil }
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
