/// Workspace-diffs access bound to the shell's current Mac connection.
extension MobileShellComposite {
    /// A workspace-diffs service over the current connection, or `nil` when not connected.
    public func makeDiffsService() -> MobileDiffsService? {
        guard connectionState == .connected, let client = remoteClient else { return nil }
        return MobileDiffsService(client: client)
    }
}
