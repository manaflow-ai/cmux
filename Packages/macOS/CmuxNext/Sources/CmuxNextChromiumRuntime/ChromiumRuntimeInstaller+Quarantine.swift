import Foundation

extension ChromiumRuntimeInstaller {
    /// Removes `com.apple.quarantine` from every item (the app downloaded
    /// the pack itself and verified it against its signed pin). Gatekeeper's
    /// quarantine is an Apple attribute: elsewhere nothing carries it.
    static func removeQuarantine(in root: URL) {
        #if canImport(Darwin)
        let rootPath = root.path
        removexattr(rootPath, "com.apple.quarantine", XATTR_NOFOLLOW)
        guard let enumerator = FileManager.default.enumerator(atPath: rootPath) else { return }
        while let relative = enumerator.nextObject() as? String {
            removexattr(rootPath + "/" + relative, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
        #endif
    }
}
