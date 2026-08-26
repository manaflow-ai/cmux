import CMUXMobileCore
public import CmuxMobileShellModel
import Foundation

extension MobileShellComposite {
    /// Refines a device-keyed connection status to one exact pairing row.
    ///
    /// `macConnectionStatuses` is keyed by physical device id, but a live or
    /// in-flight connection belongs to exactly one app instance at a time.
    /// `.connected` therefore only applies to the row whose instance tag
    /// matches the connected pairing; a sibling build's row and a legacy
    /// untagged row must not inherit it. A non-connected status stays visible
    /// on the device row while it reconnects or is unavailable, except when
    /// the foreground pairing on the same device is known to be a different
    /// build: that sibling row must not show the foreground's redial state.
    public static func exactPairingConnectionStatus(
        deviceStatus: MobileMacConnectionStatus?,
        connectedMacDeviceID: String?,
        connectedMacInstanceTag: String?,
        rowMacDeviceID: String,
        rowInstanceTag: String?
    ) -> MobileMacConnectionStatus? {
        guard let deviceStatus else { return nil }

        let canonicalRowDeviceID = CmxMacAppInstanceIdentity(
            macDeviceID: rowMacDeviceID,
            instanceTag: nil
        ).macDeviceID
        let canonicalConnectedDeviceID = connectedMacDeviceID.map {
            CmxMacAppInstanceIdentity(macDeviceID: $0, instanceTag: nil).macDeviceID
        }
        let normalizedConnectedTag = connectedMacInstanceTag.flatMap {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let normalizedRowTag = rowInstanceTag.flatMap {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        guard deviceStatus == .connected else {
            // Reconnecting/unavailable with a known same-device foreground
            // pairing of a different build (tagged or legacy untagged)
            // belongs to that pairing only; with no known target the device
            // status passes through so a redial never renders as silently
            // Not Connected.
            if canonicalConnectedDeviceID == canonicalRowDeviceID,
               let normalizedConnectedTag,
               normalizedConnectedTag != normalizedRowTag {
                return nil
            }
            return deviceStatus
        }
        guard canonicalConnectedDeviceID == canonicalRowDeviceID else { return nil }
        return normalizedConnectedTag == normalizedRowTag ? deviceStatus : nil
    }
}
