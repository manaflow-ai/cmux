public import CmuxNextWakeups
import Foundation

extension WebUpdater {
    /// The keys a pointer's signature is checked against.
    public enum KeySource: Sendable {
        /// These keys (tests).
        case keys(WebUpdateKeys)
        /// This build's `web-update-keys.json` (``WebUpdateKeys/loadBundled()``), read on the files lane of
        /// the app's one `BackgroundWork` the first time a pointer needs it, never in a static initializer
        /// on whichever thread asks first.
        case bundled(BackgroundWork)
    }

    /// The trusted keys, read once: the first pointer check awaits the bundled file on the files lane.
    ///
    /// - Throws: `CancellationError` when the check is cancelled or quit drops the read.
    func trustedKeys() async throws -> WebUpdateKeys {
        if let loadedKeys { return loadedKeys }
        let keys: WebUpdateKeys
        switch keySource {
        case .keys(let given):
            keys = given
        case .bundled(let work):
            keys = try await work.run(.bestEffort, mayBlock: .files) { WebUpdateKeys.loadBundled() }
        }
        loadedKeys = keys
        return keys
    }
}
