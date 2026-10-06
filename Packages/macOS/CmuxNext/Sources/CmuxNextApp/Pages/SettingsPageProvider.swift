import AppKit
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Observation

/// Serves the React Settings page's `cmux.settings/1` ops (webviews/src/pages/settings/ops.ts)
/// from the app's `SettingsController`: the same validated writer, file watcher and managed-key
/// guard as every other settings writer (palette, CLI `settings.set`).
///
/// INTERIM OWNER (R82): the daemon serves no `settings.*` v2 ops yet. When its config actor
/// does, `PageFactory.settingsPage` routes `cmux.settings.` to `DaemonPageRelay` and this type
/// goes; the page does not change, because the shapes and codes here are the daemon's.
@MainActor
final class SettingsPageProvider: PageProvider {
    private let settings: SettingsController
    /// Value domains the page offers in menus (`themes`, `font_families`, `sounds`).
    private let domains: @MainActor () -> [String: [String]]
    /// Live lists Settings shows beside the schema rows (spaces, machines, browser profiles); nil
    /// in tests without an app.
    private let hostLists: (@MainActor () -> JSONValue)?
    /// The Accounts part of the page (R82 commit 3): its state, and one gesture; nil in tests
    /// without an app.
    var accountsState: (@MainActor () -> JSONValue)?
    var accountsRun: (@MainActor (JSONValue) async throws -> JSONValue)?
    /// The theme picker's write (level, spec or nil) and its spec check (R82 commit 4).
    var setTheme: (@MainActor (_ level: String, _ spec: String?) throws -> Void)?
    var acceptsTheme: (@MainActor (String) -> Bool)?
    /// The cmux picker for folders (R89): the paths the person chose (`~/` for home), nil when
    /// they left it.
    var pickFolders: (@MainActor () async -> [String]?)?
    /// The registry's buttons for a section (`SettingsSchema.actions(in:)`): id, localized title,
    /// and whether it can run now.
    var sectionActions: (@MainActor (SettingsSection) -> JSONValue)?
    /// Results of recent writes by idempotency key (a retried key replays its first answer).
    private var replies: [(key: String, value: JSONValue)] = []
    private static let replayLimit = 64

    init(settings: SettingsController, domains: @escaping @MainActor () -> [String: [String]] = { [:] },
         hostLists: (@MainActor () -> JSONValue)? = nil) {
        self.settings = settings
        self.domains = domains
        self.hostLists = hostLists
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case "cmux.settings.list": return list(section: params["section"]?.stringValue)
        case "cmux.settings.snapshot": return snapshot()
        case "cmux.settings.set":
            guard let value = params["value"] else { throw PageError.invalidParams("value is required") }
            let descriptor = try descriptor(params)
            return try await mutation(params) { try await self.write(descriptor, value == .null ? nil : value, by: Self.writer(context)); return [descriptor.id] }
        case "cmux.settings.reset":
            let descriptor = try descriptor(params)
            return try await mutation(params) { try await self.write(descriptor, nil, by: Self.writer(context)); return [descriptor.id] }
        case "cmux.settings.reset_all":
            return try await mutation(params) {
                let before = self.settings.snapshot.root
                do {
                    try await self.settings.resetAllSettings(by: Self.writer(context))
                } catch let userOnly as SettingUserOnly {
                    throw Self.userOnlyError(userOnly)
                }
                await self.settings.reload()
                return SettingsSchema.all.filter { $0.storedValue(in: before) != $0.storedValue(in: self.settings.snapshot.root) }.map(\.id)
            }
        case "cmux.settings.host.lists":
            guard let hostLists else { throw PageError(code: "cmux.page.unavailable", message: "no host lists") }
            return hostLists()
        case "cmux.settings.accounts.state":
            guard let accountsState else { throw PageError(code: "cmux.page.unavailable", message: "no accounts") }
            return accountsState()
        case "cmux.settings.accounts.run":
            guard let accountsRun else { throw PageError(code: "cmux.page.unavailable", message: "no accounts") }
            return try await accountsRun(params)
        case "cmux.settings.theme.set":
            guard let setTheme else { throw PageError(code: "cmux.page.unavailable", message: "no theme host") }
            guard let level = params["level"]?.stringValue else { throw PageError.invalidParams("level is required") }
            do { try setTheme(level, params["spec"]?.stringValue) } catch { throw PageError.invalidParams("unknown theme level \(level)") }
            return .object([:])
        case "cmux.settings.theme.accepts":
            return ["accepts": .bool(acceptsTheme?(params["text"]?.stringValue ?? "") ?? false)]
        case "cmux.settings.folders.add":
            // A folder list row's Add (picker.pinned, files.roots): the person chooses in the
            // native cmux picker, so the write is theirs even for a user-only key.
            let descriptor = try descriptor(params)
            guard descriptor.kind == .folderList else { throw PageError.invalidParams("\(descriptor.id) is not a folder list") }
            guard let pickFolders else { throw PageError(code: "cmux.page.unavailable", message: "no folder picker") }
            guard let chosen = await pickFolders(), !chosen.isEmpty else { return ["added": []] }
            let current = (descriptor.effectiveValue(in: settings.snapshot.root)?.arrayValue ?? []).compactMap(\.stringValue)
            let added = chosen.filter { !current.contains($0) }
            if !added.isEmpty {
                // concurrency-allow: the settings owner writes through its CmuxConfigFile actor, off the main actor
                try await write(descriptor, .array((current + added).map(JSONValue.string)), by: .user)
            }
            return ["added": .array(added.map(JSONValue.string))]
        case "cmux.settings.section.actions":
            guard let name = params["section"]?.stringValue, let section = SettingsSection(rawValue: name) else {
                throw PageError.invalidParams("section is required")
            }
            return sectionActions?(section) ?? .array([])
        case "cmux.settings.file.reveal":
            NSWorkspace.shared.activateFileViewerSelecting([settings.file.url])
            return .object([:])
        case "cmux.settings.preview":
            // Live preview (R82 commit 5): the value applies to every window without a write;
            // the gesture's end writes it with cmux.settings.set, or preview.end restores.
            let descriptor = try descriptor(params)
            let value = params["value"].flatMap { $0 == .null ? nil : $0 }
            if let source = settings.managedSource(for: descriptor) {
                throw PageError(code: "cmux.settings.managed", message: "\(descriptor.id) is managed", details: Self.managedInfo(source))
            }
            guard Self.writer(context).mayWrite(descriptor) else {
                throw Self.userOnlyError(SettingUserOnly(key: descriptor.id, writer: Self.writer(context)))
            }
            guard settings.preview(descriptor, value) else {
                throw PageError(code: "cmux.settings.invalid", message: "\(descriptor.id) does not accept this value")
            }
            return ["previewing": .string(descriptor.id)]
        case "cmux.settings.preview.end":
            settings.endPreview()
            return .object([:])
        case "cmux.settings.sound.play":
            guard let name = params["name"]?.stringValue else { throw PageError.invalidParams("name is required") }
            if name != "default", name != "none" { NSSound(named: NSSound.Name(name))?.play() }
            return .object([:])
        default:
            throw PageError.unknownOp(op)
        }
    }

    /// `cmux.settings.changed`: one event per load that changed schema keys (any writer: this
    /// page, the palette, the CLI or a hand edit of the file).
    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        if stream == "cmux.settings.accounts.changed", let accountsState {
            return Self.watch(accountsState, onEvent: onEvent)
        }
        if stream == "cmux.settings.host.changed", let hostLists {
            return Self.watch(hostLists, onEvent: onEvent)
        }
        guard stream == "cmux.settings.changed" else { throw PageError.unknownOp(stream) }
        let settings = settings
        let task = Task { @MainActor in
            var last = settings.snapshot.root
            for await (count, root) in Observations({ (settings.loadCount, settings.snapshot.root) }) {
                let keys = SettingsSchema.all.filter { $0.storedValue(in: root) != $0.storedValue(in: last) }.map(\.id)
                last = root
                if !keys.isEmpty { onEvent(["revision": .number(Double(count)), "keys": .array(keys.map(JSONValue.string))]) }
            }
        }
        return PageSubscription { task.cancel() }
    }

    /// One event per change of `read`'s value (the stores it reads are observable); the event
    /// carries the new value.
    private static func watch(_ read: @escaping @MainActor () -> JSONValue,
                              onEvent: @escaping @MainActor (JSONValue) -> Void) -> PageSubscription {
        let task = Task { @MainActor in
            var last = read()
            for await value in Observations({ read() }) where value != last {
                last = value
                onEvent(value)
            }
        }
        return PageSubscription { task.cancel() }
    }

    // MARK: Reads

    private func list(section: String?) -> JSONValue {
        let root = settings.snapshot.root
        let file = settings.fileRoot
        return .array(SettingsSchema.all.filter { section == nil || $0.section.rawValue == section }.map { descriptor in
            [
                "key": .string(descriptor.id),
                "value": descriptor.effectiveValue(in: root) ?? .null,
                "default": descriptor.defaultValue ?? .null,
                "customized": .bool(descriptor.isCustomized(in: file)),
                "managed": settings.managedSource(for: descriptor).map(Self.managedInfo) ?? .null,
            ]
        })
    }

    private func snapshot() -> JSONValue {
        var managed: [String: JSONValue] = [:]
        for (key, source) in settings.managedKeys { managed[key] = Self.managedInfo(source) }
        var published: [String: JSONValue] = [:]
        for (name, values) in domains() { published[name] = .array(values.map(JSONValue.string)) }
        return [
            "revision": .number(Double(settings.loadCount)),
            // The page checks no hash yet; the daemon owner will send the export's.
            "schema_hash": "",
            "effective": settings.snapshot.root,
            "managed": .object(managed),
            "diagnostics": .array(settings.diagnostics.map { ["path": .string($0.path), "message": .string($0.message)] }),
            "domains": .object(published),
        ]
    }

    // MARK: Writes

    private func descriptor(_ params: JSONValue) throws -> SettingDescriptor {
        let key = params["key"]?.stringValue ?? ""
        let path = CmuxConfigFile.keyPath(from: key)
        if SettingsSchema.isRetired(path) { throw PageError(code: "cmux.settings.removed", message: "\(key) was removed") }
        guard let descriptor = SettingsSchema.descriptor(for: path) else {
            throw PageError(code: "cmux.settings.invalid", message: "\(key) is not a setting")
        }
        return descriptor
    }

    /// Runs one write and answers the v2 mutation result; a retried idempotency key replays.
    private func mutation(_ params: JSONValue, _ write: () async throws -> [String]) async throws -> JSONValue {
        let key = params["idempotency_key"]?.stringValue
        if let key, let reply = replies.first(where: { $0.key == key }) {
            guard case .object(var members) = reply.value else { return reply.value }
            members["replayed"] = .bool(true)
            return .object(members)
        }
        let keys = try await write()
        let value: JSONValue = ["value": ["keys": .array(keys.map(JSONValue.string))],
                                "revision": .string(String(settings.loadCount)), "replayed": false]
        if let key {
            replies.append((key, value))
            if replies.count > Self.replayLimit { replies.removeFirst() }
        }
        return value
    }

    /// SECURITY (agent_settable): the Settings page writes as the user only for a call backed by a
    /// real key or mouse event in its view (`context.userGesture`, the host's record) from the
    /// bundled cmux.settings page (the router admits only its trusted frame). A script write with
    /// no gesture is a page write and may change only agent-settable keys.
    static func writer(_ context: PageCallContext) -> SettingWriter {
        context.page == PageDescriptor.settings.id && context.userGesture ? .user : .caller("page")
    }

    static func userOnlyError(_ refusal: SettingUserOnly) -> PageError {
        PageError(code: "cmux.settings.user_only", message: String(describing: refusal), details: ["key": .string(refusal.key)])
    }

    private func write(_ descriptor: SettingDescriptor, _ value: JSONValue?, by writer: SettingWriter) async throws {
        do {
            try await settings.setSetting(descriptor, to: value, by: writer)
        } catch let managed as SettingManaged {
            throw PageError(code: "cmux.settings.managed", message: String(describing: managed), details: Self.managedInfo(managed.source))
        } catch let refused as SettingRefused {
            throw PageError(code: "cmux.settings.invalid", message: String(describing: refused))
        } catch let userOnly as SettingUserOnly {
            throw Self.userOnlyError(userOnly)
        }
        // The watcher applies the write; reading it back now keeps the page's refresh current.
        await settings.reload()
    }

    static func managedInfo(_ source: ManagedSource) -> JSONValue {
        switch source {
        case .device: ["source": "device", "reason": "device", "team": .null]
        case .team(let name): ["source": "team", "reason": "team", "team": name.isEmpty ? .null : .string(name)]
        }
    }
}

/// The value domains the Settings page offers in menus, listed once per launch.
@MainActor
enum SettingsPageDomains {
    /// Installed fixed-pitch families the terminal accepts, sorted.
    static let fontFamilies: [String] = {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        let families = Set(names.compactMap { NSFont(name: $0, size: 0)?.familyName })
            .filter { TerminalFontSetting().isValidFamily($0) && !$0.hasPrefix(".") }
        return families.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }()

    /// The sounds in /System/Library/Sounds.
    static let sounds: [String] = {
        let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/System/Library/Sounds"),
                                                                  includingPropertiesForKeys: nil)) ?? []
        return urls.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }()
}
