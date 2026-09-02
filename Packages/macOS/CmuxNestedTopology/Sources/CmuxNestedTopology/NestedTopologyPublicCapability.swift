/// Semantic capabilities that cmux advertises to control-socket clients for
/// nested topology (cmux → clients/UI), distinct from provider-negotiated
/// ``NestedProviderCapability`` tokens.
///
/// These are advertised through `system.capabilities` (additive `capabilities`
/// array) and gate method availability alongside beta flags and authorization.
public enum NestedTopologyPublicCapability: String, Codable, Sendable, Hashable, CaseIterable {
    /// Read-only nested topology projection (`nested.topology.list`, optional
    /// `system.tree` `include_nested`).
    case readV1 = "nested_topology.read.v1"
    /// Capability-gated nested focus (`nested.node.focus`).
    case focusV1 = "nested_topology.focus.v1"
    /// ssh-tmux-style Herdr window mirror (real tabs/panes, layout, I/O).
    case windowMirrorV1 = "nested_topology.window_mirror.v1"
}
