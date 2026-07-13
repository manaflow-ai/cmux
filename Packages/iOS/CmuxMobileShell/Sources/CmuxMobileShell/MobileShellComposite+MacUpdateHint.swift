internal import CMUXMobileCore
internal import CmuxMobileDiagnostics

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
        let hint = MobileMacUpdateAdvisor.hint(
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

        guard !MobileMacUpdateHintDismissalStore().isDismissed(
            macDeviceID: macDeviceID,
            signature: hint.dismissalSignature
        ) else {
            clearMacUpdateHint()
            return
        }

        macUpdateHint = hint
        macUpdateHintMacDeviceID = macDeviceID
        // Keyed per Mac so two hosts sharing one gap signature each emit a
        // shown event, while reconnects to the same host stay deduplicated.
        guard macUpdateHintShownSignatures.insert("\(macDeviceID)|\(hint.dismissalSignature)").inserted else { return }
        analytics.capture("ios_mac_update_hint_shown", analyticsProperties(for: hint))
    }

    /// Permanently dismisses the currently visible gap for this Mac and version target.
    public func dismissMacUpdateHint() {
        guard let hint = macUpdateHint, let macDeviceID = macUpdateHintMacDeviceID else { return }
        MobileMacUpdateHintDismissalStore().dismiss(
            macDeviceID: macDeviceID,
            signature: hint.dismissalSignature
        )
        clearMacUpdateHint()
        analytics.capture("ios_mac_update_hint_dismissed", analyticsProperties(for: hint))
    }

    /// Clears connection-scoped hint state without resetting the session analytics gate.
    func clearMacUpdateHint() {
        macUpdateHint = nil
        macUpdateHintMacDeviceID = nil
    }

    private func analyticsProperties(for hint: MobileMacUpdateHint) -> [String: AnalyticsValue] {
        [
            "mac_app_version": .string(hint.macAppVersion.description),
            "minimum_mac_version": .string(hint.minimumMacVersion.description),
            "features": .string(hint.features.map(\.rawValue).joined(separator: ",")),
        ]
    }
}
