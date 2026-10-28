import AppKit
import CmuxNextCompat
import CmuxNextDiff
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Observation

/// One file page's look, shared by its tabs (diff-host.md, `cmux.markdown.look`,
/// `cmux.editor.look`): the page's settings section (`markdown`, `editor` in cmux.json),
/// `<config dir>/<section>/theme.css`, and for the editor the shared `appearance.syntaxTheme`, the
/// user language pack and whether VoiceOver runs. A change of any is pushed to every listener with
/// only the keys that changed; preference writes (PAGE-PREFS) go to the settings file and show at
/// once, before the file watcher reloads. The look's followers write to every listening page (its
/// router holds the push while a page is hidden), so they flush as visible-class work on the app's
/// scheduler, behind the person's input.
final class FilePageLook {
    private let kind: FilePageKind
    private let settings: () -> SettingsController?
    private let fixedConfigDirectory: URL?
    private var listeners: [UUID: @MainActor (JSONValue) -> Void] = [:]
    private var themeCSS = ""
    private var themeWatcher: ConfigFileWatcher?
    /// Bumped by every theme read and by ``stop()``: an older read's reply applies nothing.
    private var themeGeneration = 0
    private var settingsWatch: ServiceObservation<LookSettings>?
    private let mainWork: MainWorkScheduler
    /// The app's lanes: the theme and import reads run on their files lane.
    private let work: BackgroundWork
    private var languageFeed: DiffLanguageFeed?
    private var stopLanguages: (() -> Void)?
    private var languages: JSONValue?
    /// Preference writes not yet seen in the settings file, by path.
    private var pending: [[String]: JSONValue] = [:]
    private var lastSent: JSONValue = .object([:])
    /// The code editor's defaults from another editor's settings (`editor.importFrom`): the
    /// mapped section, which editor it came from, and the files watched for a change.
    private let importSources: EditorSettingsSources
    private var imported: JSONValue = .object([:])
    private(set) var importedFrom: ImportableEditor?
    private var importChoice: EditorImportChoice?
    private var importWatchers: [ConfigFileWatcher] = []
    /// Bumped by every import read and by ``stop()``: an older read's reply applies nothing.
    private var importGeneration = 0

    /// `configDirectory`: where `<section>/theme.css` lives; nil uses the settings file's folder.
    /// `importSources`: where the code editor reads another editor's settings (the home folder).
    /// `mainWork`: the app's main-thread scheduler (`AppServices.mainWork`); `work`: the app's lanes
    /// (`AppServices.work`), where the theme and import files are read.
    init(kind: FilePageKind, settings: @escaping () -> SettingsController?, configDirectory: URL? = nil,
         importSources: EditorSettingsSources = EditorSettingsSources(home: FileManager.default.homeDirectoryForCurrentUser),
         mainWork: MainWorkScheduler, work: BackgroundWork) {
        self.mainWork = mainWork
        self.work = work
        self.kind = kind
        self.settings = settings
        fixedConfigDirectory = configDirectory
        self.importSources = importSources
    }

    /// `markdown.remoteImages`: whether documents load web images without a click (default false).
    /// A false value still permits the current document after its visible load control is clicked.
    var remoteImages: Bool {
        settings()?.fileRoot["markdown"]?["remoteImages"]?.boolValue ?? false
    }

    private var configDirectory: URL? { fixedConfigDirectory ?? settings()?.file.url.deletingLastPathComponent() }

    /// The look now (the page config carries it).
    func current() -> JSONValue {
        start()
        var look: [String: JSONValue] = ["settings": section(), "themeCSS": .string(themeCSS)]
        if kind == .editor {
            look["syntaxTheme"] = settings()?.fileRoot["appearance"]?["syntaxTheme"] ?? .null
            look["screenReader"] = .bool(NSWorkspace.shared.isVoiceOverEnabled)
            if let languages { look["languages"] = languages }
        }
        return .object(look)
    }

    func listen(_ onLook: @escaping @MainActor (JSONValue) -> Void) -> () -> Void {
        start()
        let id = UUID()
        listeners[id] = onLook
        lastSent = current()
        return { [weak self] in self?.listeners[id] = nil }
    }

    /// The settings section with pending writes applied; for the code editor, over the defaults
    /// taken from another editor (a key set in cmux.json wins).
    private func section() -> JSONValue {
        var value = settings()?.fileRoot[kind.section] ?? .object([:])
        if value.objectValue == nil { value = .object([:]) }
        if kind == .editor { value = EditorSettingsImport.section(imported: imported, own: value) }
        for (path, written) in pending {
            let stored = Self.value(at: Array(path.dropFirst()), in: value)
            if stored == written { pending[path] = nil }
            value = Self.setting(written, at: Array(path.dropFirst()), in: value)
        }
        return value
    }

    /// Writes one validated `<section>.<key>` through the one settings write path
    /// (`SettingsController.setSetting(at:to:by:)`): a key the schema does not list is refused, a
    /// user-only key needs `.user` (a call backed by a real gesture). Never a raw file write.
    func setPreference(key: String, value: JSONValue, by writer: SettingWriter) async throws {
        guard let settings = settings() else { throw SettingsDiffPrefs.Unavailable() }
        let path = key.split(separator: ".").map(String.init)
        try await settings.setSetting(at: path, to: value == .null ? nil : value, by: writer)
        pending[path] = value
        publish()
    }

    // MARK: Watching

    private func start() {
        guard settingsWatch == nil else { return }
        let section = kind.section
        let settings = settings
        // Its first value is the look `current()` reads now: only later changes publish (the guard
        // skips the apply inside `init`, which would start this again from `current()`).
        settingsWatch = ServiceObservation(.visible, owner: "file-look.settings", on: mainWork) {
            LookSettings(section: settings()?.fileRoot[section], syntaxTheme: settings()?.fileRoot["appearance"]?["syntaxTheme"])
        } apply: { [weak self] _ in
            guard let self, self.settingsWatch != nil else { return }
            self.followImportChoice()
            self.publish()
        }
        let mainWork = mainWork
        if let directory = configDirectory {
            let file = directory.appending(path: section).appending(path: "theme.css")
            let watcher = ConfigFileWatcher(url: file) { [weak self] in
                mainWork.postFromAnyThread(.visible, owner: "file-look.theme") { self?.readTheme(file) }
            }
            themeWatcher = watcher
            watcher.start()
            if kind == .editor {
                followImportChoice()
                let feed = DiffLanguageFeed(directory: DiffLanguagePack.directory(configFile: directory.appending(path: "cmux.json")),
                                            mainWork: mainWork)
                languageFeed = feed
                stopLanguages = feed.listen { [weak self] pack in
                    self?.languages = pack
                    self?.publish()
                }
            }
        }
    }

    // MARK: Another editor's settings

    /// Reads the chosen editor's settings again when `editor.importFrom` changed.
    private func followImportChoice() {
        guard kind == .editor else { return }
        let choice = EditorImportChoice(setting: settings()?.fileRoot["editor"]?["importFrom"]?.stringValue)
        guard choice != importChoice else { return }
        importChoice = choice
        importWatchers.forEach { $0.stop() }
        let mainWork = mainWork
        importWatchers = importSources.watchedFiles(choice).map { file in
            let watcher = ConfigFileWatcher(url: file) { [weak self] in
                mainWork.postFromAnyThread(.visible, owner: "file-look.import") { self?.readImport() }
            }
            watcher.start(reportInitialChange: false)
            return watcher
        }
        readImport()
    }

    /// Reads the chosen editor's settings on the files lane; the newest read's reply applies them.
    private func readImport() {
        guard let choice = importChoice else { return }
        importGeneration += 1
        let generation = importGeneration, sources = importSources
        work.run(.userVisible, mayBlock: .files) { sources.load(choice) }
            .reply(on: mainWork, class: .visible, owner: "file-look.import") { [weak self] found in
                guard let self, self.importGeneration == generation else { return }
                self.importedFrom = found?.editor
                let section = found?.section ?? .object([:])
                guard section != self.imported else { return }
                self.imported = section
                self.publish()
            }
    }

    /// The defaults taken from another editor now (the Import Settings action copies them).
    var importedSection: JSONValue { imported }

    /// Reads `file` (the page's theme.css) on the files lane; the newest read's reply applies it.
    private func readTheme(_ file: URL) {
        themeGeneration += 1
        let generation = themeGeneration
        work.run(.userVisible, mayBlock: .files) { Self.theme(at: file) }
            .reply(on: mainWork, class: .visible, owner: "file-look.theme") { [weak self] text in
                guard let self, self.themeGeneration == generation, text != self.themeCSS else { return }
                self.themeCSS = text
                self.publish()
            }
    }

    /// The theme file's text, "" when it cannot be read; on the files lane.
    private nonisolated static func theme(at file: URL) -> String {
        (try? String(blockingContentsOf: file, encoding: .utf8)) ?? ""
    }

    /// Sends the keys that changed since the last event.
    private func publish() {
        let now = current()
        guard now != lastSent, let members = now.objectValue else { return }
        let before = lastSent.objectValue ?? [:]
        var changed: [String: JSONValue] = [:]
        for (key, value) in members where before[key] != value { changed[key] = value }
        lastSent = now
        guard !changed.isEmpty else { return }
        for id in listeners.keys.sorted(by: { $0.uuidString < $1.uuidString }) { listeners[id]?(.object(changed)) }
    }

    func stop() {
        settingsWatch?.cancel()
        settingsWatch = nil
        themeWatcher?.stop()
        themeWatcher = nil
        themeGeneration += 1
        stopLanguages?()
        stopLanguages = nil
        importWatchers.forEach { $0.stop() }
        importWatchers = []
        importGeneration += 1
        importChoice = nil
        listeners.removeAll()
    }

    // MARK: Paths

    static func value(at path: [String], in root: JSONValue) -> JSONValue? {
        var node: JSONValue? = root
        for part in path { node = node?[part] }
        return node
    }

    /// `root` with `value` at `path`; a boolean shorthand on the way (`minimap: false`) becomes
    /// the object it stands for (`{enabled: false}`), as the page reads it.
    static func setting(_ value: JSONValue, at path: [String], in root: JSONValue) -> JSONValue {
        guard let first = path.first else { return value }
        var members = root.objectValue ?? [:]
        let child: JSONValue = switch members[first] {
        case .bool(let flag)? where path.count > 1: ["enabled": .bool(flag)]
        case let existing?: existing
        case nil: .object([:])
        }
        members[first] = path.count == 1 ? value : setting(value, at: Array(path.dropFirst()), in: child)
        return .object(members)
    }
}

/// What a file page's look follows in the settings: its section and the shared syntax theme.
private nonisolated struct LookSettings: Equatable {
    let section: JSONValue?
    let syntaxTheme: JSONValue?
}
