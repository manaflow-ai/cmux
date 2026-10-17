internal import CmuxMobilePairedMac

extension MobileShellComposite {
    /// Returns the most useful display name for a paired Mac target.
    ///
    /// Keep the lookup keyed by the full pairing identity so two tagged
    /// instances on one Mac cannot surface the wrong host name.
    func taskComposerTargetName(macDeviceID: String, instanceTag: String?) -> String {
        displayPairedMacs.first {
            MacPairingKey($0) == MacPairingKey(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag
            )
        }?.resolvedName
            ?? pairedMacs.first {
                MacPairingKey($0) == MacPairingKey(
                    macDeviceID: macDeviceID,
                    instanceTag: instanceTag
                )
            }?.resolvedName
            ?? macDeviceID
    }

    /// Whether the foreground connection targets this exact Mac pairing.
    /// A missing tag matches only another untagged legacy pairing.
    func matchesForegroundPairing(macDeviceID: String, instanceTag: String?) -> Bool {
        guard let foregroundMacDeviceID else { return false }
        return MacPairingKey(
            macDeviceID: foregroundMacDeviceID,
            instanceTag: activeMacInstanceTag
        ) == MacPairingKey(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
    }
}
