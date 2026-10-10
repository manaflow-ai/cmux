/// A feature an administrator can turn off with the managed policy key
/// `DisabledFeatures` (spec/enterprise.md 5.2). A turned-off feature's
/// actions leave every surface: the palette, menus, shortcuts, context
/// menus, and `action.run` on the socket and CLI (`feature.disabled`).
public nonisolated enum ActionFeature: String, CaseIterable, Sendable, Hashable {
    case computerUse
    /// Browser automation runs in the browser host, not as actions; the
    /// host refuses its ops (Rust follow-up).
    case browserAutomation
    /// The MCP server runs in the `cmux` CLI; it refuses to serve (Rust follow-up).
    case mcp
    case cloud
    case apps
    case remoteHosts

    /// The feature `descriptor` belongs to, or nil. Rules by id and
    /// category, so a new action of a feature is covered with no edit;
    /// `ActionFeatureTests` pins the resulting sets.
    public static func feature(of descriptor: ActionDescriptor) -> ActionFeature? {
        let id = descriptor.id.rawValue
        let lowered = id.lowercased()
        if lowered.hasPrefix("computeruse") || id.hasPrefix("palette.computerUse.") { return .computerUse }
        if descriptor.category == .remote || id == "disconnectRemoteTab" || ["server.makeThisMacAServer", "server.addServer"].contains(id) { return .remoteHosts }
        if id.hasPrefix("app.") || id.hasPrefix("appStore.") { return .apps }
        if lowered.contains("cloud") || id == "switchRightSidebarToMachines" { return .cloud }
        return nil
    }
}

extension ActionFeature {
    /// The feature in `disabled` that `descriptor` belongs to, or nil.
    public static func turnedOff(_ descriptor: ActionDescriptor, in disabled: Set<ActionFeature>) -> ActionFeature? {
        guard !disabled.isEmpty, let feature = feature(of: descriptor), disabled.contains(feature) else { return nil }
        return feature
    }
}

extension ActionRegistry {
    /// The turned-off feature of the action `id`, or nil (DisabledFeatures).
    public func disabledFeature(for id: ActionID) -> ActionFeature? { descriptor(for: id).flatMap { ActionFeature.turnedOff($0, in: disabledFeatures) } }
}
