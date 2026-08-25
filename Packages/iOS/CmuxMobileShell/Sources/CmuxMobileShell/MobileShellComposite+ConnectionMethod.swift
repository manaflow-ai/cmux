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
            ?? .automatic
    }

    /// Returns whether a live foreground session should be replaced when the
    /// app-wide default changes. An explicit per-Computer override owns that
    /// pairing's policy and therefore makes a global default change irrelevant.
    func shouldRecoverForegroundForDefaultMethodChange(
        liveTransportMode: CmxTransportMode?,
        newDefaultTransportMode: CmxTransportMode,
        hasExplicitPairingOverride: Bool,
        hasRecoveryTarget: Bool
    ) -> Bool {
        guard !hasExplicitPairingOverride else {
            return false
        }
        guard let liveTransportMode else { return hasRecoveryTarget }
        return liveTransportMode != newDefaultTransportMode
    }

    private var foregroundHasExplicitConnectionMethodOverride: Bool {
        guard let macDeviceID = foregroundMacDeviceID ?? activeTicket?.macDeviceID,
              !macDeviceID.isEmpty else {
            return false
        }
        let canonicalDeviceID = cmxCanonicalDeviceID(macDeviceID)
        return pairedMacsForIdentityMatching.contains { pairing in
            cmxCanonicalDeviceID(pairing.macDeviceID) == canonicalDeviceID
                && pairing.instanceTag == activeMacInstanceTag
                && pairing.storedConnectionMethod != nil
        }
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
        // Only replace the foreground session when this exact pairing owns it.
        // A secondary Computer's setting must not interrupt the user's active
        // terminal; its next pool reconciliation will use the persisted mode.
        let foregroundTargetDeviceID = foregroundMacDeviceID
            ?? recoveryTargetMacDeviceID
        let foregroundTargetInstanceTag = foregroundMacDeviceID != nil
            ? activeMacInstanceTag
            : recoveryTargetInstanceTag
        let affectsForeground = cmxCanonicalDeviceID(foregroundTargetDeviceID ?? "")
            == canonical
            && (instanceTag == nil || foregroundTargetInstanceTag == targetInstanceTag)
        if affectsForeground {
            recoverMobileConnection(trigger: .connectionMethodChanged)
        } else {
            scheduleSecondaryAggregation()
        }
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
            let foregroundTargetDeviceID = foregroundMacDeviceID
                ?? recoveryTargetMacDeviceID
            let foregroundTargetInstanceTag = foregroundMacDeviceID != nil
                ? activeMacInstanceTag
                : recoveryTargetInstanceTag
            let affectsForeground = cmxCanonicalDeviceID(foregroundTargetDeviceID ?? "")
                == canonical
                && (targetInstanceTag == nil || foregroundTargetInstanceTag == targetInstanceTag)
            if affectsForeground {
                recoverMobileConnection(trigger: .connectionMethodChanged)
            } else {
                scheduleSecondaryAggregation()
            }
        }
    }

    /// The method-pinned Iroh dial allowlist for one pairing, or `nil` when the
    /// pairing's effective method places no address pin on the Iroh dial.
    ///
    /// Direct pins the dial to the user-enabled addresses. Tailscale Only on an
    /// Iroh-identified pairing pins the dial to the pairing's numeric Tailscale
    /// addresses: the method constrains PATHS while transport admission stays
    /// the single auth authority, so control, background control, and terminal
    /// lanes all live and die by the same dial policy. Legacy pairings without
    /// an Iroh identity return `nil` and keep the grant-gated raw host lane.
    ///
    /// An empty array means the method is pinned with nothing dialable:
    /// callers must fail closed and never substitute another path. Entries
    /// with an out-of-range explicit port are carried port-less (the store's
    /// editor validates the range).
    func irohMethodPinnedDialCandidates(
        forMacDeviceID macDeviceID: String,
        instanceTag: String?,
        knownPairing: MobilePairedMac? = nil
    ) -> [CmxIrohDirectDialCandidate]? {
        let canonical = cmxCanonicalDeviceID(macDeviceID)
        // Same sibling rule as `connectionMethod(forMacDeviceID:instanceTag:)`:
        // an explicit tag must not pin another build's address allowlist.
        let pairing = knownPairing ?? pairedMacs.first {
            $0.macDeviceID == canonical
                && (instanceTag == nil || $0.instanceTag == instanceTag)
        } ?? (instanceTag == nil ? pairedMacs.first { $0.macDeviceID == canonical } : nil)
        guard let pairing else { return nil }
        switch connectionMethod(for: pairing) {
        case .direct:
            return pairing.directAddresses.filter(\.enabled).map { entry in
                CmxIrohDirectDialCandidate(
                    address: entry.address,
                    port: entry.port.flatMap { UInt16(exactly: $0) }
                )
            }
        case .tailscale:
            // Tailscale Only is a distinct wire transport. Even a Tailscale
            // address carried as an Iroh hint would violate the user's hard
            // no-fallback contract, so this mode never constructs an Iroh
            // allowlist.
            return nil
        case .automatic:
            return nil
        case .lan, .iroh:
            return nil
        }
    }

    /// Zero-touch discovery yields Iroh candidates only. Tailscale-only mode
    /// intentionally disables it because Iroh is outside that policy. LAN-only
    /// still needs an Iroh identity as its encrypted bootstrap, so discovery
    /// remains available for a first pairing or a stale route set.
    var zeroTouchIrohDiscoveryDisabled: Bool {
        guard let defaultMethod = connectionMethodStore?.method,
              defaultMethod == .tailscale else {
            return false
        }
        return pairedMacs.allSatisfy {
            let method = connectionMethod(for: $0)
            return method != .automatic && method != .iroh && method != .direct
        }
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
                if self.shouldRecoverForegroundForDefaultMethodChange(
                    liveTransportMode: self.remoteClient?.transportMode,
                    newDefaultTransportMode: method.transportMode,
                    hasExplicitPairingOverride: self.foregroundHasExplicitConnectionMethodOverride,
                    hasRecoveryTarget: self.foregroundMacDeviceID != nil
                        || self.recoveryTargetMacDeviceID != nil
                ) {
                    self.recoverMobileConnection(trigger: .connectionMethodChanged)
                }
                // Pairings without an override inherit this shared default.
                // Reconcile warm secondary clients immediately so their
                // immutable transport requests do not outlive the setting.
                self.scheduleSecondaryAggregation()
            }
        }
    }
}
