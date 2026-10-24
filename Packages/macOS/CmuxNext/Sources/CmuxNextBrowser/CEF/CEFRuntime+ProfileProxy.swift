import Foundation

/// A browser profile's own proxy in Chromium (#24432): the profile's
/// persistent request context uses it from its first request.
extension CEFRuntime {
    /// Hands `profile`'s proxy (or its clear) to the shim when it changed since
    /// the shim last took it. False when the shim refused it: the caller must
    /// not open a page of the profile then (fail closed).
    func applyProfileProxy(_ profile: BrowserProfileID) -> Bool {
        guard let shim else { return false }
        let key = storage.contextKey(for: profile, machineKey: nil, offTheRecord: false)
        if unappliedProfileProxies.contains(profile) {
            let proxy = profileProxies[profile]
            let stored = key.withCString { path in
                (proxy?.chromiumServer ?? "").withCString { server in
                    (proxy?.chromiumBypassList ?? "").withCString { bypass in shim.setContextProxyServer(path, server, bypass) }
                }
            }
            guard stored == 1 else {
                logger.error("browser profile proxy refused by the shim")
                return false
            }
            unappliedProfileProxies.remove(profile)
        }
        guard profileProxies[profile] != nil else { return true }
        return shim.contextProxyState(key) >= 0
    }
}
