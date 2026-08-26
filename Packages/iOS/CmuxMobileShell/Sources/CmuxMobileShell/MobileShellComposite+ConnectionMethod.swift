internal import CMUXMobileCore
public import CmuxMobilePairedMac
public import CmuxMobileShellModel

extension MobilePairedMac {
    /// This iPhone's explicit connection-method choice for this pairing,
    /// decoded from the device-local store column. Retired persisted values
    /// from older builds fail the raw-value init and read as `nil` (the app
    /// default, which is also Tailscale). `nil` = no explicit choice.
    var storedConnectionMethod: MobileConnectionMethod? {
        connectionMethodRawValue.flatMap(MobileConnectionMethod.init(rawValue:))
    }
}

@MainActor
extension MobileShellComposite {
    /// The effective connection method for one pairing: its own stored choice,
    /// else the app-wide default. Tailscale is the only method.
    public func connectionMethod(for mac: MobilePairedMac) -> MobileConnectionMethod {
        mac.storedConnectionMethod ?? connectionMethodStore?.method ?? .tailscale
    }

    /// The effective connection method for a pairing identified by device and
    /// optional tag. With a nil tag this resolves the device's first stored
    /// pairing, matching the legacy device-level call sites. An explicit tag
    /// never falls back to a sibling build's row: methods are chosen per
    /// build, so an unstored tagged pairing uses the app default instead of
    /// inheriting whichever sibling happens to be stored first.
    public func connectionMethod(
        forMacDeviceID macDeviceID: String,
        instanceTag: String?
    ) -> MobileConnectionMethod {
        let canonical = cmxCanonicalDeviceID(macDeviceID)
        let match = pairedMacs.first {
            $0.macDeviceID == canonical
                && (instanceTag == nil || $0.instanceTag == instanceTag)
        } ?? (instanceTag == nil ? pairedMacs.first { $0.macDeviceID == canonical } : nil)
        return match.map(connectionMethod(for:))
            ?? connectionMethodStore?.method
            ?? .tailscale
    }

    /// Persist the per-Computer connection method and, when the change affects
    /// the foreground Mac, replace the live connection so the new method takes
    /// effect immediately instead of on the next dial.
    public func setConnectionMethod(
        _ method: MobileConnectionMethod?,
        macDeviceID: String,
        instanceTag: String?
    ) async {
        // Same scope resolution as updateMacCustomization: the stored row's
        // owner key embeds user + team, so a nil scope would update nothing.
        guard let pairedMacStore, let scope = await currentScopeSnapshot() else { return }
        let canonical = cmxCanonicalDeviceID(macDeviceID)
        let targetInstanceTag = instanceTag
            ?? displayPairedMacs.first(where: { $0.macDeviceID == canonical })?.instanceTag
        try? await pairedMacStore.setConnectionMethod(
            macDeviceID: canonical,
            instanceTag: targetInstanceTag,
            rawValue: method?.rawValue,
            stackUserID: scope.userID,
            teamID: scope.teamID
        )
        await loadPairedMacs()
        // A method change affects dialing whether or not the Mac is currently
        // connected — the OLD method may be exactly what disconnected it (for
        // example Tailscale Only without a grant). Mirror the legacy app-wide
        // observer and always run recovery, which redials with the new method.
        recoverMobileConnection(trigger: .connectionMethodChanged)
    }

    /// Observes the shared Settings/onboarding choice and replaces any live
    /// foreground connection whose route was selected under the old method.
    func startObservingConnectionMethodChanges() {
        guard connectionMethodObservationTask == nil,
              let connectionMethodStore else { return }
        let initialMethod = connectionMethodStore.method
        connectionMethodObservationTask = Task { @MainActor [weak self, connectionMethodStore] in
            var observedMethod = initialMethod
            for await method in connectionMethodStore.changes() {
                guard let self, !Task.isCancelled else { return }
                guard method != observedMethod else { continue }
                observedMethod = method
                self.recoverMobileConnection(trigger: .connectionMethodChanged)
            }
        }
    }
}
