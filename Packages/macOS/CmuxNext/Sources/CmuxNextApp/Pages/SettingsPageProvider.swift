import AppKit
import CmuxNextCompat
import CmuxNextDesign
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
    /// Value domains the page offers in menus (`themes`, `font_families`, `sounds`, `recent_fonts`).
    private let domains: @MainActor () -> [String: [String]]
    /// Live lists Settings shows beside the schema rows (spaces, machines, browser profiles); nil
    /// in tests without an app.
    private let hostLists: (@MainActor () -> JSONValue)?
    /// The Accounts part of the page (R82 commit 3): its state, and one gesture; nil in tests
    /// without an app.
    var accountsState: (@MainActor () -> JSONValue)?
    var accountsRun: (@MainActor (JSONValue) async throws -> JSONValue)?
    /// Settings > Agents (BRING-YOUR-OWN-HARNESS): the harness list and its gestures; nil in tests
    /// without an app.
    var agents: AgentHarnessCenter?
    /// Settings > Agents > Harnesses (cx-mg91, `SettingsHarnesses`): its state, and one gesture;
    /// nil in tests without an app.
    var harnessesState: (@MainActor () -> JSONValue)?
    var harnessesRun: (@MainActor (JSONValue, PageCallContext?) async throws -> JSONValue)?
    /// Settings > Devices (the device hub): its state, one gesture, and the
    /// watch that keeps its history current while a page shows it; nil in
    /// tests without an app.
    var devicesState: (@MainActor () -> JSONValue)?
    var devicesRun: (@MainActor (JSONValue) async throws -> JSONValue)?
    var devicesWatching: (@MainActor (Bool) -> Void)?
    /// Settings > Agents > Agent integrations (`SettingsAgentIntegrations`): the coding-agent
    /// hooks `cmux agent hook` installs; nil in tests without an app.
    var integrations: (any PageProvider)?
    /// The theme picker's write (level, spec or nil) and its spec check (R82 commit 4).
    var setTheme: (@MainActor (_ level: String, _ spec: String?) throws -> Void)?
    var acceptsTheme: (@MainActor (String) -> Bool)?
    /// Every published theme's colors (`cmux.settings.theme.colors`), for the Theme section's
    /// preview and swatches; nil in tests without an app.
    var themeColors: (@MainActor () -> [ThemeFileColors])?
    /// A folders-only NSOpenPanel returning absolute paths; injectable without opening UI in tests.
    var pickChatFolders: @MainActor () async -> [String]? = { await ChatRootPicker().choose() }
    /// The cmux picker for folders (R89): the paths the person chose (`~/` for home), nil when
    /// they left it.
    var pickFolders: (@MainActor () async -> [String]?)?
    /// Save as Ghostty Theme and Import Theme File (`cmux.settings.theme.save`/`.import`).
    var themeFiles: SettingsThemeFiles?
    /// The backgrounds folder and its image picker (`cmux.settings.backdrop.choose_image`).
    var backdropImages: SettingsBackdropImages?
    /// Browse more art: the museum search's results for this page.
    var museumArt: MuseumArtSession?
    var workspaceBackgrounds: SettingsWorkspaceBackgrounds?
    /// The registry's buttons for a section (`SettingsSchema.actions(in:)`): id, localized title,
    /// and whether it can run now.
    var sectionActions: (@MainActor (SettingsSection) -> JSONValue)?
    /// Settings > Devices' Remove (plans/cmux-next/add-device-DESIGN.md 2.5): the error to show, or nil.
    var removeDevice: (@MainActor (String) async -> String?)?
    /// Settings > Devices' Full access switch on a paired client machine: the error to show, or nil.
    var setDeviceFullAccess: (@MainActor (String, Bool) async -> String?)?
    /// The gesture (``PageCallContext/gestureEvent``) that last turned a device's Full access on:
    /// one click or key turns on one setting.
    private var spentFullAccessGesture: TimeInterval?
    /// Results of recent writes by idempotency key (a retried key replays its first answer).
    private var replies: [(key: String, value: JSONValue)] = []
    private static let replayLimit = 64

    init(settings: SettingsController, domains: @escaping @MainActor () -> [String: [String]] = { [:] },
         hostLists: (@MainActor () -> JSONValue)? = nil) {
        self.settings = settings
        self.domains = domains
        self.hostLists = hostLists
    }

    /// A theme's colors as the page reads them (`GhosttyTheme` in webviews/src/theme/ghosttyTheme.ts).
    static func json(_ colors: ThemeFileColors) -> JSONValue {
        var object: [String: JSONValue] = [
            "name": .string(colors.name),
            "background": .string(AppTheme.hex(colors.background)),
            "foreground": .string(AppTheme.hex(colors.foreground)),
            "palette": .array(colors.palette.map { $0.map { .string(AppTheme.hex($0)) } ?? .null }),
        ]
        for (key, color) in [("selectionBackground", colors.selectionBackground), ("selectionForeground", colors.selectionForeground),
                             ("cursorColor", colors.cursorColor), ("cursorText", colors.cursorText), ("accent", colors.accent)] {
            if let color { object[key] = .string(AppTheme.hex(color)) }
        }
        return .object(object)
    }

    /// A host the App wires in (nil in tests without an app), or the page's `cmux.page.unavailable`.
    private static func host<Host>(_ host: Host?, _ name: String) throws -> Host {
        guard let host else { throw PageError(code: "cmux.page.unavailable", message: "no \(name)") }
        return host
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
        case "cmux.settings.host.lists": return try Self.host(hostLists, "host lists")()
        case "cmux.settings.devices.remove":
            guard let id = params["id"]?.stringValue else { throw PageError.invalidParams("id is required") }
            return try await Self.host(removeDevice, "devices")(id).map { ["error": .string($0)] } ?? .object([:])
        case "cmux.settings.devices.full_access":
            guard let id = params["id"]?.stringValue, let on = params["on"]?.boolValue else {
                throw PageError.invalidParams("id and on are required")
            }
            // SECURITY: turning Full access on lets that machine's chats edit files and run
            // commands here without asking, so it needs the person's own click or key in the
            // Settings page, spent once (the host's record, never the page's word): page script
            // alone never turns it on. Turning it off only narrows what the machine may do, so it
            // needs no gesture (a revoke always works, assistive technology included).
            if on {
                guard context.page == PageDescriptor.settings.id, context.userGesture, let event = context.gestureEvent,
                      event != spentFullAccessGesture else {
                    throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage)
                }
                spentFullAccessGesture = event
            }
            return try await Self.host(setDeviceFullAccess, "devices")(id, on).map { ["error": .string($0)] } ?? .object([:])
        case "cmux.settings.accounts.state": return try Self.host(accountsState, "accounts")()
        case "cmux.settings.accounts.run": return try await Self.host(accountsRun, "accounts")(params)
        case "cmux.settings.agents.state": return try Self.host(agents, "agents").pageState
        case "cmux.settings.agents.run": return try await Self.host(agents, "agents").runPage(params)
        case "cmux.settings.harnesses.state": return try Self.host(harnessesState, "harnesses")()
        case "cmux.settings.harnesses.run": return try await Self.host(harnessesRun, "harnesses")(params, context)
        case "cmux.settings.integrations.state", "cmux.settings.integrations.run":
            return try await Self.host(integrations, "agent integrations").call(op, params: params, context: context)
        case "cmux.settings.devices.state": return try Self.host(devicesState, "devices")()
        case "cmux.settings.devices.run": return try await Self.host(devicesRun, "devices")(params)
        case "cmux.settings.theme.set":
            guard let setTheme else { throw PageError(code: "cmux.page.unavailable", message: "no theme host") }
            guard let level = params["level"]?.stringValue else { throw PageError.invalidParams("level is required") }
            do { try setTheme(level, params["spec"]?.stringValue) } catch { throw PageError.invalidParams("unknown theme level \(level)") }
            return .object([:])
        case "cmux.settings.theme.colors": return try ["themes": .array(Self.host(themeColors, "theme colors")().map(Self.json))]
        case "cmux.settings.theme.save", "cmux.settings.theme.import":
            guard let themeFiles else { throw PageError(code: "cmux.page.unavailable", message: "no theme files") }
            return try await themeFiles.call(op, params: params, edits: settings.applied.themeEdits, writer: Self.writer(context))
        case "cmux.settings.theme.accepts":
            return ["accepts": .bool(acceptsTheme?(params["text"]?.stringValue ?? "") ?? false)]
        case "cmux.settings.folders.add":
            // A folder list row's Add (picker.pinned, files.roots): the person chooses in the
            // native cmux picker, so the write is theirs even for a user-only key.
            let descriptor = try descriptor(params)
            guard descriptor.kind == .folderList else { throw PageError.invalidParams("\(descriptor.id) is not a folder list") }
            if descriptor.path == ChatSettings.rootsPath, Self.writer(context) != .user {
                throw Self.userOnlyError(SettingUserOnly(key: descriptor.id, writer: Self.writer(context)))
            }
            let picker = descriptor.path == ChatSettings.rootsPath ? pickChatFolders : pickFolders
            guard let picker else { throw PageError(code: "cmux.page.unavailable", message: "no folder picker") }
            guard let chosen = await picker(), !chosen.isEmpty else { return ["added": []] }
            let source = descriptor.path == ChatSettings.rootsPath ? settings.fileRoot : settings.snapshot.root
            let current = (descriptor.storedValue(in: source)?.arrayValue ?? []).compactMap(\.stringValue)
            let added = chosen.filter { !current.contains($0) }
            if !added.isEmpty {
                // concurrency-allow: the settings owner writes through its CmuxConfigFile actor, off the main actor
                try await write(descriptor, .array((current + added).map(JSONValue.string)), by: .user)
            }
            return ["added": .array(added.map(JSONValue.string))]
        case "cmux.settings.backdrop.choose_image":
            return try await chooseBackdropImage()
        case "cmux.settings.backdrop.wallpaper_settings":
            AppleWallpapers.settingsURL.map { NSWorkspace.shared.openInBackground($0) }
            return .object([:])
        case "cmux.settings.art.search", "cmux.settings.art.use":
            return try await museumArt(op, params: params)
        case "cmux.settings.backdrop.workspace", "cmux.settings.backdrop.workspace.set", "cmux.settings.backdrop.workspace.preview":
            return try workspaceBackground(op, params: params, context: context)
        case "cmux.settings.section.actions":
            guard let name = params["section"]?.stringValue, let section = SettingsSection(rawValue: name) else {
                throw PageError.invalidParams("section is required")
            }
            return sectionActions?(section) ?? .array([])
        case "cmux.settings.file.reveal":
            NSWorkspace.shared.revealInBackground([settings.file.url])
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
        if stream == "cmux.settings.agents.changed", let agents {
            // The daemon's harness events reach the list only while a page shows it.
            agents.beginWatching()
            let watch = Self.watch({ agents.pageState }, onEvent: onEvent)
            return PageSubscription {
                watch.cancel()
                Task { @MainActor in agents.endWatching() }
            }
        }
        if stream == "cmux.settings.devices.changed", let devicesState {
            // The history follows the hub's pushes only while a page shows the card.
            devicesWatching?(true)
            let watch = Self.watch(devicesState, onEvent: onEvent)
            let watching = devicesWatching
            return PageSubscription {
                watch.cancel()
                Task { @MainActor in watching?(false) }
            }
        }
        if stream == "cmux.settings.harnesses.changed", let harnessesState {
            return Self.watch(harnessesState, onEvent: onEvent)
        }
        if stream == "cmux.settings.host.changed", let hostLists {
            return Self.watch(hostLists, onEvent: onEvent)
        }
        guard stream == "cmux.settings.changed" else { throw PageError.unknownOp(stream) }
        let settings = settings
        // Capture before returning the subscription so an immediate mutation cannot become
        // the task's baseline and disappear from the first event.
        let initialRoot = settings.snapshot.root
        let initialFileRoots = settings.fileRoot.value(at: ChatSettings.rootsPath)
        let initialManagedRoots = settings.managedChatRoots
        let task = Task { @MainActor in
            var last = initialRoot
            var lastFileRoots = initialFileRoots
            var lastManagedRoots = initialManagedRoots
            for await (count, root, fileRoots, managedRoots) in ObservationStream({
                (settings.loadCount, settings.snapshot.root, settings.fileRoot.value(at: ChatSettings.rootsPath), settings.managedChatRoots)
            }) {
                let keys = SettingsSchema.all.filter {
                    $0.storedValue(in: root) != $0.storedValue(in: last)
                        || ($0.path == ChatSettings.rootsPath && (fileRoots != lastFileRoots || managedRoots != lastManagedRoots))
                }.map(\.id)
                lastFileRoots = fileRoots
                lastManagedRoots = managedRoots
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
            for await value in ObservationStream({ read() }) where value != last {
                last = value
                onEvent(value)
            }
        }
        return PageSubscription { task.cancel() }
    }

    // MARK: Reads

    private func list(section: String?) -> JSONValue {
        let root = settings.snapshot.root
        return .array(SettingsSchema.all.filter { section == nil || $0.section.rawValue == section }.map { descriptor in
            var row: JSONValue = [
                "key": .string(descriptor.id),
                "value": descriptor.effectiveValue(in: root) ?? .null,
                "default": settings.defaultValue(of: descriptor) ?? .null,
                "customized": .bool(settings.isCustomized(descriptor)),
                "managed": settings.managedSource(for: descriptor).map(Self.managedInfo) ?? .null,
            ]
            if descriptor.path == ChatSettings.rootsPath, case .object(var members) = row {
                members["folders"] = settings.chatRootRows
                members["user_roots"] = settings.fileRoot.value(at: ChatSettings.rootsPath) ?? .array([])
                row = .object(members)
            }
            return row
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

    /// SECURITY (agent_settable): a call from the bundled cmux.settings page (the router admits
    /// only its trusted frame) is the user's: any interaction with the page, a click, a key or an
    /// accessibility press (which reaches the page with no AppKit event, so `context.userGesture`
    /// cannot be required without locking out assistive technology). Posted GUI input cannot be
    /// told apart from a person's on macOS, so user-only keys are protected on the automation
    /// paths instead: the CLI, agents, scripts and the control socket's `settings.set` write as
    /// their origin and are refused. Any other page writes as a page.
    static func writer(_ context: PageCallContext) -> SettingWriter {
        context.page == PageDescriptor.settings.id ? .user : .caller("page")
    }

    static func userOnlyError(_ refusal: SettingUserOnly) -> PageError {
        PageError(code: "cmux.settings.user_only", message: String(describing: refusal), details: ["key": .string(refusal.key)])
    }

    func write(_ descriptor: SettingDescriptor, _ value: JSONValue?, by writer: SettingWriter) async throws {
        do {
            try await settings.setSetting(descriptor, to: value, by: writer)
        } catch let managed as SettingManaged {
            throw PageError(code: "cmux.settings.managed", message: String(describing: managed), details: Self.managedInfo(managed.source))
        } catch let refused as SettingRefused {
            let reasons = descriptor.path == ChatSettings.rootsPath
                ? (refused.value.arrayValue ?? []).compactMap { $0.stringValue.flatMap { ChatRootValidator().refusal($0) } } : []
            throw PageError(code: "cmux.settings.invalid", message: reasons.first ?? String(describing: refused))
        } catch let userOnly as SettingUserOnly {
            throw Self.userOnlyError(userOnly)
        }
        // setSetting returns once its own load applied the write (reloadAfterWrite), so the
        // page's next read is current without a second full load and apply.
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
