import AppKit
import CmuxNextAgentPane
import CmuxNextActions
import CmuxNextCloud
import CmuxNextDesign
import CmuxNextImportCards
import CmuxNextPages
import CmuxNextSettings
import CmuxNextServer
import CmuxNextSettingsWindow
import CmuxNextTerminal
import CmuxNextUpdater
import CmuxNextWebUpdates

/// What the React Settings page shows beside the schema rows (R82 commit 2): `cmux.settings.host.lists`.
/// Spaces (nil when this daemon has no profiles), saved machines, browser profiles, and the
/// profile color swatches. Edits run catalog actions (`browserProfile.*`) through
/// `cmux.app.action.run`, the same path as the palette and the CLI.
extension SettingsWindowService {
    /// The whole host lists, every section built now (the `cmux.settings.host.lists` read).
    func pageHostLists() -> JSONValue {
        SettingsHostSection.merged(pageHostSections().map { $0.read() })
    }

    /// The host lists by section, each filling its own keys (hq#20297): the page's watch observes each
    /// on its own (``SettingsHostSection/watch(_:onEvent:)``), so a change rebuilds only its section.
    func pageHostSections() -> [SettingsHostSection] {
        func section(_ name: String, _ build: @escaping @MainActor @Sendable (SettingsWindowService) -> [String: JSONValue]) -> SettingsHostSection {
            SettingsHostSection(name: name) { [weak self] in self.map(build) ?? [:] }
        }
        return [
            // dev_build: the Development category (dev_only) shows in DEV and NIGHTLY builds; Devices in every build.
            // harness_placement: raw legacy preference; the web shares its fallback policy with the model picker.
            section("build") { _ in ["dev_build": .bool(DevTools.isEnabled), "harness_placement": .string(AgentPaneTunables.harnessPlacement.value.rawValue)] },
            section("rooms") { $0.rooms.map { ["rooms": .array($0.map(\.hostJSON))] } ?? ["rooms": .null] },
            section("machines") { window in ["machines": .array(window.machines.map { window.vmHostRow($0.machineHostJSON, id: $0.id) })] },
            // Settings > Devices (plans/cmux-next/add-device-DESIGN.md 2.4): every device, one remove.
            section("devices") { ["devices": (try? JSONValue.parse($0.services.devices.pageData(phones: $0.services.iphone.devicePhones))) ?? .null] },
            // This Mac's one-line join consent (labs.machineJoin): null unless joined.
            section("devices_join") { ["devices_join": $0.services.joinConsent.pageData().flatMap { try? JSONValue.parse($0) } ?? .null] },
            section("browser_profiles") { window in
                ["browser_profiles": .array(window.browserProfiles.map { profile in
                    [
                        "id": .string(profile.id), "name": .string(profile.name),
                        "color": profile.color.map(JSONValue.string) ?? .null, "icon": profile.icon.map(JSONValue.string) ?? .null,
                        "is_default": .bool(profile.isDefault), "source": profile.source.map(JSONValue.string) ?? .null,
                    ]
                }),
                 "profile_colors": .array(GroupColor.allCases.map { color in
                     // Opaque colors only (hex drops alpha).
                     ["name": .string(color.rawValue), "swatch": .string(SettingsListRow.hex(color.markColor)), "fill": .string(SettingsListRow.hex(color.chipFill))]
                 })]
            },
            section("theme") { window in
                // The app scope and the Ghostty runtime are not observable; reading the store's
                // generation makes this section re-send the Ghostty config preview, the terminal
                // facts and the derived sliders after a config edit.
                let services = window.services
                _ = services.themeStore.generation
                let levels = window.themeLevels
                return [
                    // R82 commit 4: theme levels of the active window, terminal facts, the settings file
                    // and the wallpaper choices (thumbnails at cmux-page://cmux.settings/backdrop/<id>).
                    "theme": [
                        "levels": .array(levels.map { .string($0.rawValue) }),
                        "current": .object(Dictionary(uniqueKeysWithValues: levels.map { level in
                            (level.rawValue, window.theme(at: level).map(JSONValue.string) ?? .null)
                        })),
                        // "Use Ghostty Config"'s preview (the config's own colors, null while appearance.theme is set); the pair side the terminals use.
                        "config": services.settings?.snapshot.appTheme == nil ? Self.themeJSON(services.themeStore.configInput) : .null,
                        "system_scheme": .string(NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"),
                    ],
                    "terminal": ["ghostty_config": .string(window.ghosttyConfigPath), "shell_integration": window.shellIntegration.map(JSONValue.string) ?? .null],
                    "derived": .object(window.pageDerivedNumbers()),
                ]
            },
            section("ghostty_diagnostics") { _ in
                // R92: the Ghostty lines cmux does not apply (the socket's `ghostty.diagnostics` list).
                ["ghostty_diagnostics": GhosttyDiagnosticsModel.shared.diagnostics.map { .array($0.map(GhosttyDiagnosticsControl.json)) } ?? .null,
                 // The Theme section's notice: colors the Ghostty config sets itself, which no theme changes.
                 "theme_overrides": .array(GhosttyDiagnosticsModel.shared.colorOverrides.map { override in
                     ["key": .string(override.key), "file": .string((override.file as NSString).abbreviatingWithTildeInPath), "line": .number(Double(override.line))]
                 })]
            },
            // Computer Use Setup (Agents): the helper's grants, the same state as the palette action.
            section("computer_use") { ["computer_use": $0.services.onboarding.computerUseSetup.pageJSON] },
            section("iphone") { ["iphone": $0.services.iphone.pageJSON] },
            // Settings > Server: status, version line, Restart Recommended, socket and tailnet address.
            section("server") { ["server": $0.services.serverUpdates.settingsPageJSON] },
            section("import_suggestions") { _ in ["import_suggestions": ImportSuggestionsCenter.shared.settingsJSON] },
            section("web_updates") { _ in ["web_updates": WebUpdates.shared.pageJSON] },
            section("app_update") { ["app_update": $0.services.updater.settingsPageJSON] },
            // Chief > Voice input: home.voiceInput, null where the tunable does not exist (Release).
            section("voice_input") { _ in ["voice_input": ChiefVoiceInputPageRoute().hostJSON] },
            // Settings > Menus: every right-click menu's rows and the person's arrangement of it.
            section("context_menus") { ["context_menus": $0.contextMenusRoute.hostJSON] },
            section("settings_file") { ["settings_file": $0.services.settings.map { .string($0.file.url.path(percentEncoded: false)) } ?? .null] },
            section("backdrops") { window in ["backdrops": window.backdropRowsCache.rows(for: window.backdropCatalog.catalog)] },
        ]
    }

    /// Where unset number rows' sliders sit, by schema key: the window opacity the theme resolved,
    /// and each size row's live value (``SettingsUnsetSizes``).
    func pageDerivedNumbers() -> [String: JSONValue] {
        SettingsUnsetSizes(terminalFontSize: GhosttyRuntime.shared.configuredFontSize,
                           backingScale: services.windows.active?.window?.backingScaleFactor ?? 2)
            .derivedNumbers(windowOpacity: derivedNumber(at: WindowBackgroundSetting.opacityPath))
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
        let owns = session?.appLink.ownership.callerOwnsVM == true
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
}
