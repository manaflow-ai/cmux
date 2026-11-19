extension DaemonCapability {
    /// What a connection echoes in `set-client-info`.
    ///
    /// - Parameters:
    ///   - advertised: The capabilities the connection advertises.
    ///   - resolvesShellIntegration: The connection resolves Ghostty's shell integration itself.
    ///   - echoesPlacementShift: This build orders sidebar rows from the sidebar document only
    ///     (the App passes true from its composition root).
    public static func handshakeCapabilities(_ advertised: [String], resolvesShellIntegration: Bool,
                                             echoesPlacementShift: Bool = false) -> [String] {
        // The document path echoes `placement-shift-v1` together with `sidebar-doc-v1`.
        let document = echoesPlacementShift && advertised.contains(Self.sidebarDoc.rawValue) ? [Self.placementShift.rawValue] : []
        let shell = resolvesShellIntegration ? [Self.terminalFrontendShellIntegration.rawValue] : []
        return advertised + shell + document
    }
}
