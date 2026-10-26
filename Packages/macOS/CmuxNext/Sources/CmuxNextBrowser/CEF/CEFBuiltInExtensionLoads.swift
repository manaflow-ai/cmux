import Foundation

/// The built-in extensions that load into each persistent profile right before its first browser tab
/// (p13-webui-055, feature `chromiumAdBlockerAtFirstTab`). Through `--load-extension` they loaded into
/// every profile Chromium started, the root profile no cmux tab uses too, so Home with no browser tab
/// ran the built-in uBlock Origin's background page in a renderer of its own. Chrome loads
/// `--load-extension` folders synchronously at a profile's start "to avoid a race between extension
/// loading and loading an URL from the command line" (chrome/browser/extensions/unpacked_installer.cc,
/// `LoadFromCommandLine`); the fork's `cmux_ext_load_command_line` makes the same load and queues it on
/// the profile's init callbacks ahead of the tab's create, so the first page still loads with it.
nonisolated struct CEFBuiltInExtensionLoads: Equatable, Sendable {
    /// The feature `chromiumAdBlockerAtFirstTab` (the App sets it before Chromium starts).
    var featureOn = false
    /// The folders each first tab loads; empty: they loaded at start, or none is on.
    private(set) var folders: [String] = []
    /// The context keys the folders were loaded into by this Chromium.
    private(set) var loadedContexts: Set<String> = []

    /// A Chromium start (also a Chromium Host's restart): `folders` load at first tabs, into no profile yet.
    mutating func started(folders: [String]) {
        self.folders = folders
        loadedContexts = []
    }

    /// The folders to load before a tab of `key` (context `contextKey`) is created: all of them for a
    /// persistent profile's first tab; none for an incognito or cmux page store (in memory: cmux runs
    /// no extension there, browser.md "Extensions in incognito") or a profile already loaded.
    mutating func foldersBeforeTab(of key: CEFPaneKey, contextKey: String) -> [String] {
        guard !folders.isEmpty, !key.offTheRecord, loadedContexts.insert(contextKey).inserted else { return [] }
        return folders
    }
}

extension CEFRuntime {
    /// Loads the built-in extensions into the profile of `host` before `tab`'s browser is created
    /// (``CEFBuiltInExtensionLoads``): a post in call order, so in host mode the host queues the load
    /// ahead of the tab's create too. Nothing for a spare's placeholder (Home keeps no extension
    /// renderer), when they loaded at start, or when the profile has them already.
    func loadBuiltInExtensions(before tab: CEFTab, in host: CEFPaneHost) {
        guard !builtInLoads.folders.isEmpty, host.placeholder !== tab, let shim else { return }
        let key = contextKey(for: host.key)
        for folder in builtInLoads.foldersBeforeTab(of: host.key, contextKey: key) {
            _ = shim.extLoadCommandLine(key, folder)
        }
    }
}

extension CEFEngine {
    /// The default-off feature `chromiumAdBlockerAtFirstTab` (``CEFBuiltInExtensionLoads``): the built-in
    /// ad blocker loads at each profile's first browser tab, not at Chromium's start. Set before Chromium
    /// starts; read once, at the start.
    public func setAdBlockerAtFirstTab(_ on: Bool) {
        CEFRuntime.shared.builtInLoads.featureOn = on
    }
}
