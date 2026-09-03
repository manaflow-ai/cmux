/// Semantic capability negotiated between a nested provider and cmux.
///
/// Prefer these tokens over guessing method shapes from protocol numbers.
public enum NestedProviderCapability: String, Codable, Sendable, Hashable, CaseIterable {
    /// Provider can return a full topology snapshot.
    case topologySnapshotV1 = "topology.snapshot.v1"
    /// Provider can stream topology/agent events.
    case topologyEventsV1 = "topology.events.v1"
    /// Provider can focus a nested node.
    case topologyFocusV1 = "topology.focus.v1"
    /// Provider can rename a nested node.
    case topologyRenameV1 = "topology.rename.v1"
    /// Provider accepts pane input.
    case paneInputV1 = "pane.input.v1"
    /// Provider can split panes.
    case paneSplitV1 = "pane.split.v1"
    /// Provider can resize a pane grid (tmux ``resize-pane`` analogue).
    case paneResizeV1 = "pane.resize.v1"
    /// Provider can close a pane (tmux ``kill-pane`` analogue).
    case paneCloseV1 = "pane.close.v1"
    /// Provider can read pane output (tmux ``%output`` analogue).
    case paneReadV1 = "pane.read.v1"
    /// Provider supports agent prompting.
    case agentPromptV1 = "agent.prompt.v1"
}
