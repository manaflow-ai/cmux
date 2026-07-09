/// The identity-free `mobile.host.status` wire payload: the reachable attach
/// routes, the terminal fidelity tier, and the advertised
/// ``MobileHostCapabilities``. This is the single shape every public
/// `mobile.host.status` reply uses (the public-status cache, the network status
/// gate, and `TerminalController`'s no-private-metadata branch), so the fields
/// cannot drift.
///
/// Identity-free by construction: routes, fidelity, and capabilities are a
/// reachability probe any peer may ask for, but the Mac's stable identity
/// (`mac_device_id`, `mac_display_name`) is never on this unauthenticated
/// surface. The app folds the Mac's identity onto a copy of ``jsonObject`` for
/// a caller that has proven same-account Stack ownership.
///
/// A real value type holding the pre-rendered route payloads, replacing the
/// former app-side static-on-`MobileHostService` builder. The routes arrive
/// already rendered to `[[String: Any]]` because that rendering depends on
/// `CmxAttachRoute.mobileHostJSONObject`, an app extension; this type only
/// assembles the surrounding dictionary.
public struct MobileHostPublicStatus {
    /// The reachable attach routes, already rendered to their wire dictionaries.
    public let routesPayload: [[String: Any]]

    /// Creates a public status value from the pre-rendered route payloads.
    public init(routesPayload: [[String: Any]]) {
        self.routesPayload = routesPayload
    }

    /// The identity-free `mobile.host.status` reply dictionary.
    public var jsonObject: [String: Any] {
        [
            "routes": routesPayload,
            "terminal_fidelity": "render_grid",
            "capabilities": MobileHostCapabilities.advertised.identifiers,
        ]
    }
}
