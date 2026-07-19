internal import CMUXMobileCore
internal import CmuxMobileDiagnostics
internal import CmuxMobileRPC

/// Session-scoped bookkeeping for the Mac-update hint: which Mac the visible
/// hint belongs to, and which (mac, gap) pairs already emitted the eligible
/// analytics event this session. A reference type so the composite can hold it
/// behind one `@ObservationIgnored` stored property (views observe only
/// `macUpdateHint` itself).
final class MacUpdateHintSessionState {
    var macDeviceID: String?
    var shownSignatures: Set<String> = []
    /// The persisted dismissal store, carried here so both the lookup and the
    /// dismissal path share one instance and tests/previews can swap in a
    /// suite-scoped store instead of touching the user's real defaults.
    var dismissalStore = MobileMacUpdateHintDismissalStore()
}

extension MobileShellComposite {
    /// Whether the Mac supports workspace group sections and collapse/expand RPCs.
    public var supportsWorkspaceGroups: Bool { supportedHostCapabilities.contains(Self.workspaceGroupsCapability) }
    /// Whether the Mac supports rename/pin workspace actions.
    public var supportsWorkspaceActions: Bool { supportedHostCapabilities.contains(Self.workspaceActionsCapability) }
    /// Whether the Mac supports mark read/unread workspace actions.
    public var supportsWorkspaceReadStateActions: Bool { supportedHostCapabilities.contains(Self.workspaceReadStateCapability) }

    /// Recomputes the visible Mac-update hint from an authoritative host status snapshot.
    ///
    /// - Parameters:
    ///   - capabilities: Capabilities decoded from `mobile.host.status`.
    ///   - statusMacAppVersion: The version carried by that status response, when available.
    ///   - macDeviceID: The stable identifier of the host that supplied the status.
    func refreshMacUpdateHint(
        capabilities: Set<String>,
        statusMacAppVersion: String?,
        macDeviceID: String?
    ) {
        let version = statusMacAppVersion ?? activeTicket?.macAppVersion
        // Fail closed without a stable Mac identity: a shared fallback key
        // would let a dismissal on one anonymous Mac suppress the hint on
        // another. Identity-free status replies usually lack the version too,
        // so this hides nothing that could have been shown truthfully.
        guard let macDeviceID, !macDeviceID.isEmpty else {
            MobileDebugLog.anchormux("macupdate.hint skipped reason=no_mac_device_id")
            clearMacUpdateHint()
            return
        }
        let hint = MobileMacUpdateHint(
            hostCapabilities: capabilities,
            macAppVersion: version
        )
        MobileDebugLog.anchormux(
            "macupdate.hint caps=\(capabilities.count) version=\(version ?? "nil") hint=\(hint?.dismissalSignature ?? "nil")"
        )
        guard let hint else {
            clearMacUpdateHint()
            return
        }

        guard !macUpdateHintSessionState.dismissalStore.isDismissed(
            macDeviceID: macDeviceID,
            signature: hint.dismissalSignature
        ) else {
            clearMacUpdateHint()
            return
        }

        macUpdateHint = hint
        macUpdateHintSessionState.macDeviceID = macDeviceID
        // Keyed per Mac so two hosts sharing one gap signature each emit an
        // event, while reconnects to the same host stay deduplicated. Named
        // "eligible" deliberately: this fires when the model computes a
        // visible hint, not when the toolbar indicator actually renders
        // (chrome, navigation state, or backgrounding can defer that).
        guard macUpdateHintSessionState.shownSignatures.insert("\(macDeviceID)|\(hint.dismissalSignature)").inserted else { return }
        analytics.capture("ios_mac_update_hint_eligible", analyticsProperties(for: hint))
    }

    /// Recovery-path refresh: when the fast transport probe times out,
    /// `scheduleHostIdentityAdoptionIfNeeded` is the only path that sees a
    /// full status payload, and skipping the hint there would leave it absent
    /// (or a previous Mac's hint stale) until the next reconnect.
    func refreshMacUpdateHintFromRecoveredStatus(_ payload: MobileHostStatusResponse) {
        refreshMacUpdateHint(
            capabilities: Set(payload.capabilities),
            statusMacAppVersion: payload.macAppVersion,
            macDeviceID: payload.macDeviceID ?? activeTicket?.macDeviceID
        )
    }

    /// Permanently dismisses the currently visible gap for this Mac and version target.
    public func dismissMacUpdateHint() {
        guard let hint = macUpdateHint, let macDeviceID = macUpdateHintSessionState.macDeviceID else { return }
        macUpdateHintSessionState.dismissalStore.dismiss(
            macDeviceID: macDeviceID,
            signature: hint.dismissalSignature
        )
        clearMacUpdateHint()
        analytics.capture("ios_mac_update_hint_dismissed", analyticsProperties(for: hint))
    }

    /// Clears connection-scoped hint state without resetting the session analytics gate.
    func clearMacUpdateHint() {
        macUpdateHint = nil
        macUpdateHintSessionState.macDeviceID = nil
    }

    private func analyticsProperties(for hint: MobileMacUpdateHint) -> [String: AnalyticsValue] {
        [
            "mac_app_version": .string(hint.macAppVersion.description),
            // Inferred lower bounds must not pollute version-segmented metrics.
            "mac_app_version_inferred": .bool(hint.isVersionInferred),
            "minimum_mac_version": .string(hint.minimumMacVersion.description),
            "features": .string(hint.features.map(\.rawValue).joined(separator: ",")),
        ]
    }
}
