import Foundation

/// Assembles the private (same-account) `mobile.host.status` wire reply for the
/// Mac's mobile data-plane RPC host: the dictionary that folds the Mac's stable
/// identity onto the host-service snapshot, the live workspace count, the
/// terminal fidelity tier, and the advertised ``MobileHostCapabilities``.
///
/// Stateless: construct one inline wherever the payload is needed; every
/// instance assembles the same shape. The app resolves the live inputs (the
/// rendered host-service payload, which depends on the app-side
/// `MobileHostServiceStatus.payload` and `CmxAttachRoute.mobileHostJSONObject`
/// extensions; the Mac identity from ``MobileHostIdentity``; and the workspace
/// count from the controller's live tab manager) and passes them in. This type
/// owns only the wire-shape decision between them, returning the `[String: Any]`
/// the app wraps in its `V2CallResult`.
///
/// The identity-free public-status branch is not assembled here: it already
/// lives in ``MobileHostPublicStatus`` and the app forwards to it directly, so
/// only the identity-bearing private branch needed lifting.
public struct MobileHostStatusPayloadBuilder: Sendable {
    /// Creates the builder. It is stateless.
    public init() {}

    /// The identity-bearing `mobile.host.status` reply dictionary returned to a
    /// caller that has proven same-account Stack ownership.
    ///
    /// Reads ``MobileHostCapabilities/advertised`` for the capability list, the
    /// single source of truth the public-status path also reads, so the two can
    /// never drift. The display name is mapped to `NSNull` when absent using an
    /// explicit branch rather than `?? NSNull()` because Swift toolchains can
    /// disagree on that operator's `Any` inference.
    ///
    /// - Parameters:
    ///   - hostServicePayload: the rendered `MobileHostServiceStatus.payload`
    ///     dictionary (the `host_service` value), pre-rendered app-side because
    ///     it depends on app extensions.
    ///   - macDeviceID: the Mac's stable device identifier.
    ///   - macDisplayName: the Mac's display name, or `nil` when unset.
    ///   - workspaceCount: the live workspace count resolved from the
    ///     controller's tab manager.
    /// - Returns: the `mobile.host.status` reply dictionary.
    public func privateStatusPayload(
        hostServicePayload: [String: Any],
        macDeviceID: String,
        macDisplayName: String?,
        workspaceCount: Int
    ) -> [String: Any] {
        let displayNameValue: Any
        if let macDisplayName {
            displayNameValue = macDisplayName
        } else {
            displayNameValue = NSNull()
        }
        return [
            "mac_device_id": macDeviceID,
            "mac_display_name": displayNameValue,
            "host_service": hostServicePayload,
            "workspace_count": workspaceCount,
            "terminal_fidelity": "render_grid",
            "capabilities": MobileHostCapabilities.advertised.identifiers,
        ]
    }
}
