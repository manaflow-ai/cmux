import Foundation
import os

/// Finds this target's resource bundle without `Bundle.module`, which traps
/// when the bundle is missing (the app's folder deleted while it runs). The
/// search matches CmuxNextDesign's `ModuleResourceBundle`; this leaf target
/// cannot import it.
nonisolated enum IconResources {
    static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "icons")

    private nonisolated final class Anchor {}

    /// The contents of `<name>.json` in the bundle, or nil when it is missing.
    static func json(named name: String) -> Data? {
        let code = Bundle(for: Anchor.self)
        let directories = [
            Bundle.main.resourceURL,
            code.resourceURL,
            Bundle.main.bundleURL,
            // `swift test` puts module bundles beside the .xctest bundle.
            code.bundleURL.deletingLastPathComponent(),
        ].compactMap { $0 }
        let bundle = directories.lazy
            .compactMap { Bundle(url: $0.appending(path: "CmuxNext_CmuxNextIcons.bundle", directoryHint: .isDirectory)) }
            .first
        guard let url = bundle?.url(forResource: name, withExtension: "json") else {
            logger.error("icon resource \(name, privacy: .public).json not found")
            return nil
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            logger.error("icon resource \(name, privacy: .public).json unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
