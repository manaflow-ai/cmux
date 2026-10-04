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
            return try await mutation(params) { try await self.write(descriptor, value == .null ? nil : value); return [descriptor.id] }
        case "cmux.settings.reset":
            let descriptor = try descriptor(params)
            return try await mutation(params) { try await self.write(descriptor, nil); return [descriptor.id] }
        case "cmux.settings.reset_all":
            return try await mutation(params) {
                let before = self.settings.snapshot.root
                try await self.settings.resetAllSettings()
                await self.settings.reload()
                return SettingsSchema.all.filter { $0.storedValue(in: before) != $0.storedValue(in: self.settings.snapshot.root) }.map(\.id)
            }
        case "cmux.settings.host.lists":
            guard let hostLists else { throw PageError(code: "cmux.page.unavailable", message: "no host lists") }
            return hostLists()
        case "cmux.settings.preview", "cmux.settings.preview.end":
            // No live preview yet: a change applies when it is written (flagged in react-pages.md S1).
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
        if stream == "cmux.settings.host.changed", let hostLists {
            // One event per change of the lists (the stores are observable); the page re-reads.
            let task = Task { @MainActor in
                var last = hostLists()
                for await lists in Observations({ hostLists() }) where lists != last {
                    last = lists
                    onEvent(lists)
                }
            }
            return PageSubscription { task.cancel() }
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

    private func write(_ descriptor: SettingDescriptor, _ value: JSONValue?) async throws {
        do {
            try await settings.setSetting(descriptor, to: value)
        } catch let managed as SettingManaged {
            throw PageError(code: "cmux.settings.managed", message: String(describing: managed), details: Self.managedInfo(managed.source))
        } catch let refused as SettingRefused {
            throw PageError(code: "cmux.settings.invalid", message: String(describing: refused))
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
