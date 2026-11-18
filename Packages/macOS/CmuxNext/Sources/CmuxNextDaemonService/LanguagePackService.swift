import CmuxNextCompat
import CmuxNextDaemon
import Foundation
import OSLog

/// The person's language on first use (CMUX-570). A NIGHTLY ships its module bundles in English
/// only and pins one pack per other language in `Contents/Resources/language-packs.json`. Once the
/// home daemon serves `language-packs-v1`, this asks it for the app's language (the main bundle's
/// first preferred localization: the person's macOS order, or the language set for cmux in System
/// Settings), and when the daemon says the pack is unpacked, makes it the source of the app's
/// strings (`Bundle.activateLanguagePack`). The daemon does the download, the sha256 check and the
/// cache; this only names the language and the folders. English shows until then, and stays when
/// the Mac is offline. A build without the manifest (a dev build ships every language) asks nothing.
@MainActor
public final class LanguagePackService {
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "language-packs")
    private weak var daemon: DaemonService?
    private let bundleID: String
    private var observation: Task<Void, Never>?
    /// The language a pack was made active for, so a daemon restart does not ask again.
    private var activated: String?

    public init(daemon: DaemonService, bundleID: String = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app.next") {
        self.daemon = daemon
        self.bundleID = bundleID
    }

    /// The home daemon's connection when it serves `language-packs-v1` (read under Observation, so
    /// a daemon that starts serving it, or a restarted one, gets the ask).
    private var connection: DaemonConnection? {
        guard let daemon, daemon.supports(DaemonCapability.languagePacks.rawValue) else { return nil }
        return daemon.connection
    }

    public func start() {
        guard let manifest = Bundle.main.url(forResource: "language-packs", withExtension: "json"),
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return }
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        guard language != "en" else { return }
        let cache = support.appending(path: bundleID, directoryHint: .isDirectory)
            .appending(path: "LanguagePacks", directoryHint: .isDirectory)
        // task-owner: lives as long as the service; event-driven (Observation)
        observation = Task { [weak self] in
            for await served in ObservationStream({ [weak self] in ObservationTrigger(self?.connection != nil) }) where served.value {
                guard let self, activated == nil, let connection else { continue }
                await ensure(language: language, manifest: manifest, cache: cache, connection: connection)
            }
        }
    }

    private func ensure(language: String, manifest: URL, cache: URL, connection: DaemonConnection) async {
        do {
            switch try await LanguagePacksClient(connection: connection).ensure(language: language, manifest: manifest, cache: cache) {
            case .ready(let root):
                activated = language
                // task-owner: awaited here; opens the pack's bundles off the main thread (each a folder listing)
                await Task.detached(priority: .userInitiated) { Bundle.activateLanguagePack(root: root) }.value
                logger.info("language pack \(language, privacy: .public) active")
            case .bundled:
                activated = language
            case .unavailable(let code, let message):
                logger.error("language pack \(language, privacy: .public): \(code, privacy: .public) \(message, privacy: .public)")
            }
        } catch {
            logger.error("language_packs.ensure: \(String(describing: error), privacy: .public)")
        }
    }
}
