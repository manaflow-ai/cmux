import AppKit
import CmuxNextActions
import CmuxNextCloud
import CmuxNextDesign
import CmuxNextImportCards
import CmuxNextPages
import CmuxNextSettings
import CmuxNextServer
import CmuxNextSettingsWindow
import CmuxNextWebUpdates

/// What the React Settings page shows beside the schema rows (R82 commit 2): `cmux.settings.host.lists`.
/// Spaces (nil when this daemon has no profiles), saved machines, browser profiles, and the
/// profile color swatches. Edits run catalog actions (`browserProfile.*`) through
/// `cmux.app.action.run`, the same path as the palette and the CLI.
extension SettingsWindowService {
    func pageHostLists() -> JSONValue {
        // The app scope is not observable; reading the store's generation makes the page's
        // host-lists watch re-send the Ghostty config preview after a config edit.
        _ = services.themeStore.generation
        return [
            // The Development category (dev_only) shows only in DEV builds; Devices shows in every build.
            "dev_build": .bool(DevTools.isDebugBuild),
            "rooms": rooms.map { .array($0.map(Self.listRow)) } ?? .null,
            "machines": .array(machines.map { vmHostRow(Self.machineRow($0), id: $0.id) }),
            // Settings > Devices (plans/cmux-next/add-device-DESIGN.md 2.4): every device, one remove.
            "devices": (try? JSONValue.parse(services.devices.pageData(phones: services.iphone.devicePhones))) ?? .null,
            // This Mac's one-line join consent (labs.machineJoin): null unless joined.
            "devices_join": services.joinConsent.pageData().flatMap { try? JSONValue.parse($0) } ?? .null,
            "browser_profiles": .array(browserProfiles.map { profile in
                [
                    "id": .string(profile.id), "name": .string(profile.name),
                    "color": profile.color.map(JSONValue.string) ?? .null, "icon": profile.icon.map(JSONValue.string) ?? .null,
                    "is_default": .bool(profile.isDefault), "source": profile.source.map(JSONValue.string) ?? .null,
                ]
            }),
            "profile_colors": .array(GroupColor.allCases.map { color in
                // Opaque colors only (hex drops alpha).
                ["name": .string(color.rawValue), "swatch": .string(Self.hex(color.markColor)), "fill": .string(Self.hex(color.chipFill))]
            }),
            // R82 commit 4: theme levels of the active window, terminal facts, the settings file
            // and the wallpaper choices (thumbnails at cmux-page://cmux.settings/backdrop/<id>).
            "theme": [
                "levels": .array(themeLevels.map { .string($0.rawValue) }),
                "current": .object(Dictionary(uniqueKeysWithValues: themeLevels.map { level in
                    (level.rawValue, theme(at: level).map(JSONValue.string) ?? .null)
                })),
                // "Use Ghostty Config"'s preview (the config's own colors, null while appearance.theme is set); the pair side the terminals use.
                "config": services.settings?.snapshot.appTheme == nil ? Self.themeJSON(services.themeStore.configInput) : .null,
                "system_scheme": .string(NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"),
            ],
            "terminal": ["ghostty_config": .string(ghosttyConfigPath), "shell_integration": shellIntegration.map(JSONValue.string) ?? .null],
            // R92: the Ghostty lines cmux does not apply (the socket's `ghostty.diagnostics` list).
            "ghostty_diagnostics": GhosttyDiagnosticsModel.shared.diagnostics.map { .array($0.map(GhosttyDiagnosticsControl.json)) } ?? .null,
            // The Theme section's notice: colors the Ghostty config sets itself, which no theme changes.
            "theme_overrides": .array(GhosttyDiagnosticsModel.shared.colorOverrides.map { override in
                ["key": .string(override.key), "file": .string((override.file as NSString).abbreviatingWithTildeInPath), "line": .number(Double(override.line))]
            }),
            // Computer Use Setup (Agents): the helper's grants, the same state as the palette action.
            "computer_use": services.onboarding.computerUseSetup.pageJSON,
            "iphone": services.iphone.pageJSON,
            // Settings > Server: status, version line, Restart Recommended, socket and tailnet address.
            "server": services.serverUpdates.settingsPageJSON,
            "import_suggestions": ImportSuggestionsCenter.shared.settingsJSON,
            "web_updates": WebUpdates.shared.pageJSON,
            // Chief > Voice input: home.voiceInput, null where the tunable does not exist (Release).
            "voice_input": ChiefVoiceInputPageRoute().hostJSON,
            // Settings > Menus: every right-click menu's rows and the person's arrangement of it.
            "context_menus": contextMenusRoute.hostJSON,
            "settings_file": services.settings.map { .string($0.file.url.path(percentEncoded: false)) } ?? .null,
            "backdrops": backdropRowsCache.rows(for: backdropCatalog.catalog),
            "derived": .object(pageDerivedNumbers()),
        ]
    }

    /// Settings > Menus' reads and writes (ContextMenusSettingsPage).
    var contextMenusRoute: ContextMenusPageProvider {
        ContextMenusPageProvider { [weak services] in
            guard let services, let settings = services.settings else { return nil }
            return ContextMenusSettingsPage(registry: services.registry, settings: settings)
        }
    }

    /// Where unset number rows' sliders sit, by schema key: the window opacity the theme resolved.
    func pageDerivedNumbers() -> [String: JSONValue] {
        var derived: [String: JSONValue] = [:]
        for path in [WindowBackgroundSetting.opacityPath] {
            guard let id = SettingsSchema.descriptor(for: path)?.id, let value = derivedNumber(at: path) else { continue }
            derived[id] = .number(value)
        }
        return derived
    }

    /// The wallpaper grid's choices (``BackdropCatalogStore``: built off main, again after a
    /// wallpaper folder changes, so an image the person just added or a macOS wallpaper they just
    /// downloaded is listed). Started on first read.
    var backdropCatalog: BackdropCatalogStore {
        let store = services.backdropCatalog
        store.start()
        return store
    }

    /// The person's own background images, in the backgrounds folder.
    static var userImages: BackdropUserImages? {
        BackdropArtDownloads.defaultFolder.map(BackdropUserImages.init(folder:))
    }

    /// The theme picker's write: the same theme actions as the palette, at `level` of the active
    /// window; nil `spec` returns the level to the Ghostty config.
    func setPageTheme(level: String, spec: String?) throws {
        guard let level = SettingsThemeLevel(rawValue: level), themeLevels.contains(level) else {
            throw ActionFailure.invalidTarget(level)
        }
        setTheme(spec, at: level)
    }

    /// Terminal colors as the page reads a theme (`GhosttyTheme`, unnamed: the page labels it).
    static func themeJSON(_ input: ThemeInput) -> JSONValue {
        var object: [String: JSONValue] = [
            "name": .string(""),
            "background": .string(AppTheme.hex(input.background)),
            "foreground": .string(AppTheme.hex(input.foreground)),
            "palette": .array((0..<16).map { $0 < input.palette.count ? .string(AppTheme.hex(input.palette[$0])) : .null }),
        ]
        if let selection = input.selectionBackground { object["selectionBackground"] = .string(AppTheme.hex(selection)) }
        if let selected = input.selectionForeground { object["selectionForeground"] = .string(AppTheme.hex(selected)) }
        return .object(object)
    }

    /// One list row; `icon` is its wire icon (the page draws an emoji, or an asset from `icon/<ref>`).
    static func listRow(_ row: SettingsListRow) -> JSONValue {
        ["id": .string(row.id), "title": .string(row.title), "subtitle": row.subtitle.map(JSONValue.string) ?? .null,
         "icon": .string(row.icon.wire), "active": .bool(row.isActive)]
    }

    /// A machine's row with its color (`appearance.machineColors`): `color`, the color its marks draw
    /// in now (the person's pick, else the automatic one), and `color_key`, the key its pick is under.
    /// Reading the color observes the store's picks, so the host lists are sent again after a pick.
    static func machineRow(_ row: SettingsListRow) -> JSONValue {
        guard case .object(var members) = listRow(row) else { return .null }
        let color = MachineColor(name: row.title)
        members["color"] = .string(hex(color.color))
        members["color_key"] = .string(color.key)
        return .object(members)
    }

    /// A Cloud machine's row with its "Dedicated agent machine" switch (`vm_host`: `on`, `busy`,
    /// `error`), once the machine answered (``CloudVmHostStore``): only a machine the Cloud API can
    /// exec on (either link), and only while the link in use says the signed-in caller owns it
    /// (``CloudLinkOwnership``, the Cloud API's `vmKind`). The machine's own answer cannot tell:
    /// `vmHost` is on by default on any Linux machine, team VMs included, and `cmuxVm` is a record
    /// its agents can write. Personal and SSH machines never get the switch, and a machine the
    /// caller does not own is never asked. `busy` (the switch disabled) while a set runs or the
    /// machine is not reachable now.
    func vmHostRow(_ row: JSONValue, id: String) -> JSONValue {
        guard case .object(var members) = row, let reach = vmHostReach(id) else { return row }
        let session = services.machines.session(id)
        let owns = (session?.link?.ownership ?? session?.appLink?.ownership)?.callerOwnsVM == true
        let store = services.cloudVmHost
        let entry = owns ? store.state(id, readable: reach) : nil
        guard let vm = Self.vmHostSwitch(entry, callerOwnsVM: owns, busy: !reach || store.setting.contains(id)) else { return row }
        members["vm_host"] = vm
        return .object(members)
    }

    /// The row's `vm_host` member, or nil for no switch (``vmHostRow(_:id:)``).
    static func vmHostSwitch(_ entry: CloudVmHostStore.Entry?, callerOwnsVM: Bool, busy: Bool) -> JSONValue? {
        guard callerOwnsVM else { return nil }
        let state: CloudVmHost.State?, error: String?
        switch entry {
        case .known(let known): (state, error) = (known, nil)
        case .failed(let why, _, let last): (state, error) = (last, why)
        case nil: return nil
        }
        guard let state else { return nil }
        return ["on": .bool(state.on), "busy": .bool(busy), "error": error.map(JSONValue.string) ?? .null]
    }

    /// Whether `id`'s vmHost can be read or set over the Cloud exec now (true), only shown from
    /// what it last said (false: not connected, or Cloud turned off), or never (nil: not a
    /// Cloud machine with exec). The row and every set ask this, so a switch
    /// drawn while connected never execs (or wakes the machine) once it is not.
    func vmHostReach(_ id: String) -> Bool? {
        // Either link: CloudService.machineAPI execs on a legacy and a Worker machine.
        guard let session = services.machines.session(id), session.machine.allows(.exec) else { return nil }
        guard !services.machines.isFeatureDisabled(.cloud) else { return false }
        if case .connected = session.daemon.store.connectionState { return true }
        return false
    }

    static func hex(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#808080" }
        let parts = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int(($0 * 255).rounded()) }
        return "#" + parts.map { String(format: "%02X", min(max($0, 0), 255)) }.joined()
    }
}
