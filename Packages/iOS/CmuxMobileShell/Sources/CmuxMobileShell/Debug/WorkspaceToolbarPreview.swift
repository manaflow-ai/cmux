#if DEBUG
extension MobileShellComposite {
    /// Seeds the workspace changes summary used by the real detail-screen UI fixture.
    /// - Parameters:
    ///   - workspaceID: RPC workspace identifier displayed by the fixture.
    ///   - chip: Summary rendered by the production changes toolbar button.
    public func seedWorkspaceToolbarPreview(workspaceID: String, chip: MobileWorkspaceChangesChip) {
        supportedHostCapabilities.insert(Self.workspaceChangesCapability)
        setWorkspaceChangeChipsByWorkspaceID([workspaceID: chip])
    }
}
#endif
