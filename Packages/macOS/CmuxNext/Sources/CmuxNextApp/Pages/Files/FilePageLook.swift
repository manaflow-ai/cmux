import AppKit
import CmuxNextSettings
import Foundation
import Observation

/// One file page's look, shared by its tabs (diff-host.md, `cmux.markdown.look`,
/// `cmux.editor.look`): the page's settings section (`markdown`, `editor` in cmux.json),
/// `<config dir>/<section>/theme.css`, and for the editor the shared `appearance.syntaxTheme`, the
/// user language pack and whether VoiceOver runs. A change of any is pushed to every listener with
/// only the keys that changed; preference writes (PAGE-PREFS) go to the settings file and show at
/// once, before the file watcher reloads.
final class FilePageLook {
    private let kind: FilePageKind
    private unowned let services: AppServices
    private var listeners: [UUID: @MainActor (JSONValue) -> Void] = [:]
    private var themeCSS = ""
    private var themeWatcher: ConfigFileWatcher?
    private var themeRead: Task<Void, Never>?
    private var settingsTask: Task<Void, Never>?
    private var languageFeed: DiffLanguageFeed?
    private var stopLanguages: (() -> Void)?
    private var languages: JSONValue?
    /// Preference writes not yet seen in the settings file, by path.
    private var pending: [[String]: JSONValue] = [:]
    private var lastSent: JSONValue = .object([:])

    init(kind: FilePageKind, services: AppServices) {
        self.kind = kind
        self.services = services
    }

    /// `markdown.remoteImages` (default true; coordinator decision for S6).
    var remoteImages: Bool {
        services.settings?.fileRoot["markdown"]?["remoteImages"]?.boolValue ?? true
    }

    private var configDirectory: URL? { services.settings?.file.url.deletingLastPathComponent() }

    /// The look now (the page config carries it).
    func current() -> JSONValue {
        start()
        var look: [String: JSONValue] = ["settings": section(), "themeCSS": .string(themeCSS)]
        if kind == .editor {
            look["syntaxTheme"] = services.settings?.fileRoot["appearance"]?["syntaxTheme"] ?? .null
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

    /// The settings section with pending writes applied.
    private func section() -> JSONValue {
        var value = services.settings?.fileRoot[kind.section] ?? .object([:])
        if value.objectValue == nil { value = .object([:]) }
        for (path, written) in pending {
            let stored = Self.value(at: Array(path.dropFirst()), in: value)
            if stored == written { pending[path] = nil }
            value = Self.setting(written, at: Array(path.dropFirst()), in: value)
        }
        return value
    }

    /// Writes `editor.minimap.enabled` (a validated key) to the settings store.
    func setPreference(key: String, value: JSONValue) async throws {
        guard let settings = services.settings else { throw SettingsDiffPrefs.Unavailable() }
        let path = key.split(separator: ".").map(String.init)
        pending[path] = value
        publish()
        if SettingsSchema.descriptor(for: path) != nil {
            try await settings.setSetting(at: path, to: value == .null ? nil : value, by: .caller("page"))
        } else if value == .null {
            try await settings.file.remove(path)
        } else {
            try await settings.file.set(value, at: path)
        }
    }

    // MARK: Watching

    private func start() {
        guard settingsTask == nil else { return }
        let section = kind.section
        settingsTask = Task { [weak self, services] in
            for await _ in Observations({ (services.settings?.fileRoot[section], services.settings?.fileRoot["appearance"]?["syntaxTheme"]) }) {
                self?.publish()
            }
        }
        if let directory = configDirectory {
            let file = directory.appending(path: section).appending(path: "theme.css")
            let watcher = ConfigFileWatcher(url: file) { [weak self] in
                // task-owner: hops one kernel event to the main actor; readTheme owns the read
                Task { @MainActor in self?.readTheme(file) }
            }
            themeWatcher = watcher
            watcher.start()
            if kind == .editor {
                let feed = DiffLanguageFeed(directory: DiffLanguagePack.directory(configFile: directory.appending(path: "cmux.json")))
                languageFeed = feed
                stopLanguages = feed.listen { [weak self] pack in
                    self?.languages = pack
                    self?.publish()
                }
            }
        }
    }

    private func readTheme(_ file: URL) {
        themeRead?.cancel()
        themeRead = Task { [weak self] in
            let text = await Self.read(file)
            guard let self, !Task.isCancelled, text != self.themeCSS else { return }
            self.themeCSS = text
            self.publish()
        }
    }

    @concurrent private static func read(_ file: URL) async -> String {
        // concurrency-allow: @concurrent, off the main actor
        (try? String(contentsOf: file, encoding: .utf8)) ?? ""
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
        settingsTask?.cancel()
        settingsTask = nil
        themeWatcher?.stop()
        themeWatcher = nil
        themeRead?.cancel()
        stopLanguages?()
        stopLanguages = nil
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
