public import CmuxNextCompat
import CmuxNextDaemon
import Foundation
import OSLog

/// The person's language on first use (CMUX-570). A NIGHTLY ships its module bundles in English
/// only and pins one pack per other language in `Contents/Resources/language-packs.json`. Once the
/// home daemon serves `language-packs-v1`, this asks it for the app's language (`app.language`
/// when it names one, ``AppLanguage/code``; for System the main bundle's first preferred
/// localization: the person's macOS order, or the language set for cmux in System Settings), and
/// when the daemon says the pack is unpacked, makes it the source of the app's strings
/// (`Bundle.activateLanguagePack`, which redraws the text that read the old one). Picking another
/// language in Settings asks for its pack. The daemon does the download, the sha256 check and the
/// cache; this only names the language and the folders. English shows until then, and stays when
/// the Mac is offline. A build without the manifest (a dev build ships every language) asks nothing.
@MainActor
public final class LanguagePackService {
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "language-packs")
    private weak var daemon: DaemonService?
    private let bundleID: String
    private var observation: Task<Void, Never>?
    private var systemLanguage = "en"
    /// The language of cmux's own native text, the app's one: `AppLanguageApplier` sets it from
    /// `app.language`, and this downloads the pack for the language it names.
    public let appLanguage = AppLanguage()
    /// The language whose pack is active (or that needs none), so a daemon restart does not ask again.
    private var activated: String?

    /// What the service asks for: the language, once the daemon serves the op.
    private struct Want: Sendable, Equatable {
        var served: Bool
        var language: String
    }

    init(daemon: DaemonService, bundleID: String = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app.next") {
        self.daemon = daemon
        self.bundleID = bundleID
    }

    /// The home daemon's connection when it serves `language-packs-v1` (read under Observation, so
    /// a daemon that starts serving it, or a restarted one, gets the ask).
    private var connection: DaemonConnection? {
        guard let daemon, daemon.supports(DaemonCapability.languagePacks.rawValue) else { return nil }
        return daemon.connection
    }

    /// Follows ``appLanguage`` (System: the system's language).
    public func start() {
        guard let manifest = Bundle.main.url(forResource: "language-packs", withExtension: "json"),
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return }
        let system = Bundle.main.preferredLocalizations.first ?? "en"
        systemLanguage = system
        let cache = support.appending(path: bundleID, directoryHint: .isDirectory)
            .appending(path: "LanguagePacks", directoryHint: .isDirectory)
        observation?.cancel()
        // task-owner: lives as long as the service; event-driven (Observation)
        let language = appLanguage
        observation = Task { [weak self] in
            let wants = ObservationStream({ [weak self] in
                ObservationTrigger(Want(served: self?.connection != nil, language: language.code ?? system))
            })
            for await want in wants where want.value.served {
                let wanted = want.value.language
                guard let self, activated != wanted, let connection else { continue }
                guard wanted != "en" else { await deactivate(for: wanted); continue }
                await ensure(language: wanted, manifest: manifest, cache: cache, connection: connection)
            }
        }
    }

    /// `language` needs no pack (English, or one the app pins none for): the strings read the app's
    /// own bundles again, not an earlier choice's pack.
    private func deactivate(for language: String) async {
        activated = language
        // task-owner: awaited here; the observers redraw off the main thread like an activation
        await Task.detached(priority: .userInitiated) { Bundle.deactivateLanguagePack() }.value
    }

    private func ensure(language: String, manifest: URL, cache: URL, connection: DaemonConnection) async {
        do {
            switch try await LanguagePacksClient(connection: connection).ensure(language: language, manifest: manifest, cache: cache) {
            case .ready(let root, let chromiumPak):
                // Chromium reads the language's pak from outside the signed app, the next time it
                // starts (`ChromiumLocalePaks`); the copy needs no activation, so it comes first.
                if let chromiumPak {
                    let folder = ChromiumLocalePaks.directory(bundleID: bundleID)
                    // task-owner: awaited here; one file copy off the main thread
                    let copied = await Task.detached(priority: .utility) { ChromiumLocalePaks.install(pak: chromiumPak, into: folder) }.value
                    if copied == nil { logger.error("Chromium locale pak for \(language, privacy: .public) was not installed") }
                }
                // The setting may have changed while the download was in flight. Do not activate
                // an older answer and briefly show the wrong language; the observation loop will
                // request the current one after this await returns.
                guard (appLanguage.code ?? systemLanguage) == language else { return }
                // task-owner: awaited here; opens the pack's bundles off the main thread (each a folder listing)
                await Task.detached(priority: .userInitiated) { Bundle.activateLanguagePack(root: root) }.value
                // The setting can also change during activation. Undo the stale activation before
                // the next observation starts the current language's request.
                guard (appLanguage.code ?? systemLanguage) == language else {
                    await Task.detached(priority: .userInitiated) { Bundle.deactivateLanguagePack() }.value
                    activated = nil
                    return
                }
                activated = language
                logger.info("language pack \(language, privacy: .public) active")
            case .bundled:
                guard (appLanguage.code ?? systemLanguage) == language else { return }
                await deactivate(for: language)
                guard (appLanguage.code ?? systemLanguage) == language else {
                    activated = nil
                    return
                }
            case .unavailable(let code, let message):
                logger.error("language pack \(language, privacy: .public): \(code, privacy: .public) \(message, privacy: .public)")
            }
        } catch {
            logger.error("language_packs.ensure: \(String(describing: error), privacy: .public)")
        }
    }
}
