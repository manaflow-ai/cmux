extension MobileShellComposite {
    /// Returns whether the latest render-grid frame for a surface is alternate screen.
    ///
    /// - Parameter surfaceID: The terminal surface identifier to inspect.
    /// - Returns: `true` when the surface is currently tracked as alternate screen.
    public func isAlternateScreen(surfaceID: String) -> Bool {
        terminalActiveScreenBySurfaceID[surfaceID] == .alternate
    }
}
