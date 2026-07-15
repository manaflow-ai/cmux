extension MobileShellComposite {
    /// Whether the Mac supports workspace close requests.
    public var supportsWorkspaceCloseActions: Bool { supportedHostCapabilities.contains(Self.workspaceCloseCapability) }
    /// Whether the Mac supports workspace move/reorder requests.
    public var supportsWorkspaceMoveActions: Bool { supportedHostCapabilities.contains(Self.workspaceMoveCapability) && allowsMacScopedWorkspaceMutations }
    /// Whether the Mac supports workspace group mutation requests.
    public var supportsWorkspaceGroupActions: Bool { supportedHostCapabilities.contains(Self.workspaceGroupActionsCapability) && allowsMacScopedWorkspaceMutations }
    /// Whether the Mac supports creating a workspace directly inside a group.
    public var supportsWorkspaceCreateInGroup: Bool { supportedHostCapabilities.contains(Self.workspaceCreateInGroupCapability) && allowsMacScopedWorkspaceMutations }
    /// Whether the Mac supports creating workspace groups from iOS.
    public var supportsWorkspaceGroupCreate: Bool { supportedHostCapabilities.contains(Self.workspaceGroupCreateCapability) && allowsMacScopedWorkspaceMutations }
    /// Whether the Mac supports dogfood feedback submission.
    public var supportsDogfoodFeedback: Bool { supportedHostCapabilities.contains(Self.dogfoodFeedbackCapability) }
}
