internal import CMUXMobileCore
public import CmuxMobilePairedMac
public import CmuxMobileShellModel

extension MobilePairedMac {
    /// This iPhone's explicit connection-method choice for this pairing,
    /// decoded from the device-local store column. `nil` = no explicit choice.
    var storedConnectionMethod: MobileConnectionMethod? {
        connectionMethodRawValue.flatMap(MobileConnectionMethod.init(rawValue:))
    }
}

@MainActor
extension MobileShellComposite {
    /// The effective connection method for one pairing: its own stored choice,
    /// else the app-wide default (legacy global setting), else automatic.
    public func connectionMethod(for mac: MobilePairedMac) -> MobileConnectionMethod {
        mac.storedConnectionMethod ?? connectionMethodStore?.method ?? .automatic
    }

    /// The effective connection method for a pairing identified by device and
    /// optional tag. With a nil tag this resolves the device's first stored
    /// pairing, matching the legacy device-level call sites.
    public func connectionMethod(
        forMacDeviceID macDeviceID: String,
        instanceTag: String?
    ) -> MobileConnectionMethod {
        let canonical = cmxCanonicalDeviceID(macDeviceID)
        let match = pairedMacs.first {
            $0.macDeviceID == canonical
                && (instanceTag == nil || $0.instanceTag == instanceTag)
        } ?? pairedMacs.first { $0.macDeviceID == canonical }
        return match.map(connectionMethod(for:))
            ?? connectionMethodStore?.method
            ?? .automatic
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

    /// Persist the per-Computer Direct dial candidates and, when the Computer
    /// currently uses the Direct method, redial so edits take effect now.
    public func setDirectAddresses(
        _ addresses: [MobilePairedMacDirectAddress],
        macDeviceID: String,
        instanceTag: String?
    ) async {
        guard let pairedMacStore, let scope = await currentScopeSnapshot() else { return }
        let canonical = cmxCanonicalDeviceID(macDeviceID)
        let targetInstanceTag = instanceTag
            ?? displayPairedMacs.first(where: { $0.macDeviceID == canonical })?.instanceTag
        try? await pairedMacStore.setDirectAddresses(
            macDeviceID: canonical,
            instanceTag: targetInstanceTag,
            rawJSON: MobilePairedMac.encodeDirectAddresses(addresses),
            stackUserID: scope.userID,
            teamID: scope.teamID
        )
        await loadPairedMacs()
        if connectionMethod(forMacDeviceID: canonical, instanceTag: targetInstanceTag) == .direct {
            recoverMobileConnection(trigger: .connectionMethodChanged)
        }
    }

    /// Zero-touch discovery yields Iroh candidates only. It is pointless only
    /// when the app default is Tailscale AND no stored pairing opted back into
    /// the automatic method — a per-Computer Iroh choice keeps discovery alive.
    var zeroTouchIrohDiscoveryDisabled: Bool {
        guard connectionMethodStore?.method == .tailscale else { return false }
        return pairedMacs.allSatisfy { connectionMethod(for: $0) != .automatic }
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
