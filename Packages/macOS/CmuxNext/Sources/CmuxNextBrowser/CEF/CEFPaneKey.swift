nonisolated struct CEFPaneKey: Hashable, Sendable {
    var pane: BrowserPaneID
    var profile: BrowserProfileID
    /// The remote-localhost derived store's machine, nil for the profile's
    /// own store. A Chromium window holds one store, so it is part of the key.
    var machineKey: String?
    /// An incognito window's store: an in-memory context, never a directory.
    var offTheRecord = false
}

nonisolated struct CEFDevToolsKey: Hashable, Sendable {
    var browser: Int32
    var message: Int32
}
