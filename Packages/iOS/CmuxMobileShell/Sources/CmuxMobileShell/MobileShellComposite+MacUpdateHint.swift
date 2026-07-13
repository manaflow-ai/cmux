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

        let resolvedMacDeviceID = macDeviceID ?? "unknown"
        guard !MobileMacUpdateHintDismissalStore().isDismissed(
            macDeviceID: resolvedMacDeviceID,
            signature: hint.dismissalSignature
        ) else {
            clearMacUpdateHint()
            return
        }

        macUpdateHint = hint
        macUpdateHintMacDeviceID = resolvedMacDeviceID
        guard macUpdateHintShownSignatures.insert(hint.dismissalSignature).inserted else { return }
        analytics.capture("ios_mac_update_hint_shown", analyticsProperties(for: hint))
    }

    /// Permanently dismisses the currently visible gap for this Mac and version target.
    public func dismissMacUpdateHint() {
        guard let hint = macUpdateHint else { return }
        let macDeviceID = macUpdateHintMacDeviceID ?? "unknown"
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
