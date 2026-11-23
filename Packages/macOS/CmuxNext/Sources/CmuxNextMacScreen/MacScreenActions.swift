public import CmuxNextActions
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextDevices
public import CmuxNextPalette
import Foundation

/// AppKit bindings shared by menus, the palette and CLI. The app supplies only tab placement
/// and identity lookup; the existing hub remains the owner of authorization and disconnect.
public struct MacScreenActions {
    let pages: MacScreenPages
    let selectedTab: () -> String?
    let providerKey: (String, String?) -> String?
    let open: (() throws -> MacScreenRecord, ActionInvocation, Bool) throws -> Void
    let refusal: (any Error) -> Void
    let listedDevices: @MainActor () async -> [MacScreenListedDevice]
    let worker: MacScreenWorkerSession

    /// - Parameters:
    ///   - refusal: Reports an open whose explicit target names nothing (`not_found`); every other failed open is
    ///     the run's own `.refused` answer.
    ///   - listedDevices: The machines `cmux device list` lists, read when a name matches no device Screen Sharing
    ///     lists, so the refusal says why that machine offers no screen. None: the refusal lists Screen Sharing's devices.
    ///   - worker: cmux Remote's worker, the host of this Mac's session in a build that bundles cmux Remote.
    public init(pages: MacScreenPages, selectedTab: @escaping () -> String?,
                providerKey: @escaping (String, String?) -> String?,
                open: @escaping (() throws -> MacScreenRecord, ActionInvocation, Bool) throws -> Void,
                refusal: @escaping (any Error) -> Void,
                listedDevices: @escaping @MainActor () async -> [MacScreenListedDevice],
                worker: MacScreenWorkerSession = .none) {
        self.pages = pages
        self.selectedTab = selectedTab
        self.providerKey = providerKey
        self.open = open
        self.refusal = refusal
        self.listedDevices = listedDevices
        self.worker = worker
    }

    /// No `cmux device list` (tests): a name Screen Sharing does not list is refused with Screen Sharing's devices.
    /// An overload, not a default: an async closure literal as a default argument is a crash class (crash_ratchet.py).
    public init(pages: MacScreenPages, selectedTab: @escaping () -> String?,
                providerKey: @escaping (String, String?) -> String?,
                open: @escaping (() throws -> MacScreenRecord, ActionInvocation, Bool) throws -> Void,
                refusal: @escaping (any Error) -> Void, worker: MacScreenWorkerSession = .none) {
        self.init(pages: pages, selectedTab: selectedTab, providerKey: providerKey, open: open, refusal: refusal,
                  listedDevices: Self.noListedDevices, worker: worker)
    }

    private static func noListedDevices() async -> [MacScreenListedDevice] { [] }

    /// - Parameter paletteRows: Adds a root palette provider: one "Screen Sharing: <device>" row per device.
    public func bind(into registry: ActionRegistry, paletteRows: ((AsyncPaletteProvider) -> Void)? = nil) {
        paletteRows?(pages.paletteProvider(registry: registry))
        // Screen Sharing ▸: the machines to view, one click each (MacScreenPickerMenu).
        registry.rowSubmenus["macScreen.open"] = { [weak registry] target, machineID in
            guard let registry else { return nil }
            return MacScreenPickerMenu(pages: pages, registry: registry).menu(target: target, machineID: machineID)
        }
        registry.bindEffect("macScreen.open", effect: { invocation in
            if let target = invocation.target, target.kind != .pane && target.kind != .tab { return .refused(Self.noPane) }
            do { try open({ try Self.record(invocation, pages: pages) }, invocation, Self.connects(invocation)) }
            catch { return refused(error, invocation) }
            return .done
        })
        registry.bindEffect("macScreen.stopViewing", effect: { invocation in
            guard let viewer = viewer(invocation) else { return .refused(Self.noViewer) }
            viewer.disconnectByPerson()
            return .done
        })
        ActionTargetVisibility.gate("macScreen.stopViewing", in: registry) { viewer($0) == nil ? Self.noViewer : nil }
        registry.bindEffect("macScreen.stopSharing", unavailable: { stopSharingUnavailable }, effect: { _ in stopSharing() })
        registry.bindEffect("macScreen.revokeViewer", unavailable: { pages.hubHost.noSessionReason }, effect: { _ in
            _ = pages.hubHost.revokeViewer()
            return .done
        })
        bindViewerControls(into: registry)
    }

    /// Stop Sharing This Mac ends this Mac's session wherever it is hosted: in the app's own host while a device
    /// is connected to it, else in cmux Remote's worker, the host in a build that bundles cmux Remote. Each host
    /// had its own palette row before (cmux Remote: End Screen Sharing Session was the worker's); Leo,
    /// 2026-11-16: "you can absolutely just do the reasonable/recommended thing in that case".
    var stopSharingUnavailable: String? {
        worker.running() ? nil : pages.hubHost.noSessionReason
    }

    func stopSharing() -> ActionEffect {
        if pages.hubHost.noSessionReason == nil {
            _ = pages.hubHost.stopSession()
            return .done
        }
        guard worker.running() else { return .refused(pages.hubHost.noSessionReason ?? "") }
        let stop = worker.stop
        // action-wait-allow: the session runs in cmux Remote's worker, another process; the menu bar item follows the hub.
        return .waiting(.externalProcess) {
            do { try await stop() } catch { return ActionWorkFailure(log: String(describing: error), reason: PlainErrorText.words(error)) }
            return nil
        }
    }

    /// A failed resolve or open as the run's own answer, so `cmux tab new-mac-screen`, an agent and the palette get
    /// the reason (the registry still shows it to a person); it used to go to `refusal` while the run answered done,
    /// and the CLI printed nothing. A name no listed device answers to waits for `cmux device list`: a machine listed
    /// there says why it offers no screen ("my-vm offers no screen: …"), never "No device is named".
    /// Leo, 2026-11-21: "...plus most of our vms (if we even have any lanes on freestyle vms yet!?) dont have screns...".
    func refused(_ error: any Error, _ invocation: ActionInvocation) -> ActionEffect {
        let failure = error as? ActionFailure
        // An explicit target that names nothing keeps its `not_found` answer, which only the app's refusal carries.
        if failure?.isNotFound == true {
            refusal(error)
            return .done
        }
        let message = failure?.message ?? RefusalStrings.describe(error)
        guard let name = Self.unlistedName(invocation, devices: pages.viewableDevices) else {
            return .refused(message, quiet: failure?.isQuiet == true)
        }
        let listed = listedDevices
        // action-wait-allow: only an open that already failed waits; `cmux device list` (another process) says whether the machine is listed and why it has no screen.
        return .waiting(.externalProcess) {
            ActionWorkFailure(refusal: .unavailable, reason: Self.noScreen(name, among: await listed()) ?? message)
        }
    }

    /// The `device` name of `invocation` when it is a name (not an id) that none of `devices` answers to.
    static func unlistedName(_ invocation: ActionInvocation, devices: [HubDevice]) -> String? {
        guard let text = invocation["device"]?.stringValue, MacScreenRecord.normalizedDeviceID(text) == nil else { return nil }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !devices.contains(where: { sameName($0.name, name) }) else { return nil }
        return name
    }

    /// "<name> offers no screen: <reason>." for the machine among `listed` that `name` names, as `deviceID` matches
    /// names; nil when none does.
    static func noScreen(_ name: String, among listed: [MacScreenListedDevice]) -> String? {
        guard let device = listed.first(where: { sameName($0.name, name) }) ?? listed.first(where: { $0.name == name }) else { return nil }
        return String(format: L.t("macScreen.actions.offersNoScreen", "%1$@ offers no screen: %2$@."), device.name, device.noScreenText)
    }

    private static func sameName(_ candidate: String, _ name: String) -> Bool {
        let keys: [(String) -> String] = [Self.folded, Self.slug]
        return keys.contains { key in
            let wanted = key(name)
            return !wanted.isEmpty && key(candidate) == wanted
        }
    }

    static func record(_ invocation: ActionInvocation, pages: MacScreenPages) throws -> MacScreenRecord {
        try record(invocation, pages: pages, devices: pages.viewableDevices)
    }

    /// `device` is the hub's device id or, from the CLI and agents, a device name (the Mac's Computer Name) among
    /// `devices`, the devices the home page lists. Names resolve here, at the action boundary: records and
    /// `MacScreenPages.record(forDevice:)` take only ids. No `device` opens the home page.
    static func record(_ invocation: ActionInvocation, pages: MacScreenPages, devices: [HubDevice]) throws -> MacScreenRecord {
        guard let value = invocation["device"] else { return MacScreenRecord(macID: nil) }
        guard let text = value.stringValue else { throw ActionFailure(message: missingDevice(among: devices)) }
        let id = try deviceID(named: text, among: devices)
        return pages.record(forDevice: id, requesting: connects(invocation) ? .view : nil)
    }

    /// The hub id `text` names: an id as is (listed or not, as before names resolved), else the one device whose
    /// name matches case-insensitively, else the one whose name matches ignoring punctuation and spacing too
    /// ("mac-mini" for "Mac Mini", "leos-mac" for "Leo’s Mac"), so a `cmux device list` name finds its Mac.
    /// An empty, unknown or ambiguous name fails with the devices it could name, as "name (id)".
    static func deviceID(named text: String, among devices: [HubDevice]) throws -> String {
        if let id = MacScreenRecord.normalizedDeviceID(text) { return id }
        var name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A `cmux device list` row id (`peer:desk-1`) names the machine; its screen host registers by that name.
        if name.hasPrefix("peer:") { name = String(name.dropFirst("peer:".count)) }
        guard !name.isEmpty else { throw ActionFailure(message: missingDevice(among: devices)) }
        for key: (String) -> String in [Self.folded, Self.slug] {
            let wanted = key(name)
            guard !wanted.isEmpty else { continue }
            let matches = devices.filter { key($0.name) == wanted }
            if matches.count == 1, let match = matches.first { return match.id }
            // One name, several registrations (a reinstall, an old hub record): the one that is online and shares
            // is the one a person means; only when that does not single one out is the name ambiguous.
            let live = matches.filter { $0.online && $0.macScreenShared }
            if matches.count > 1, live.count == 1, let match = live.first { return match.id }
            if matches.count > 1 {
                throw ActionFailure(message: String(format: L.t("macScreen.actions.ambiguousDevice", "More than one device is named “%@”: %@. Pass the id of the one to open."), name, listed(matches)))
            }
        }
        throw ActionFailure(message: unknownDevice(name, among: devices))
    }

    private static func folded(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
    private static func slug(_ name: String) -> String {
        folded(name).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
    }
    /// "Studio (0b6c…), mac-mini (5d1e…)": what a CLI caller can pass back as `--device`.
    private static func listed(_ devices: [HubDevice]) -> String {
        let rows = devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map { "\($0.name) (\($0.id))" }
        return ListFormatter.localizedString(byJoining: rows)
    }
    private static func unknownDevice(_ name: String, among devices: [HubDevice]) -> String {
        guard !devices.isEmpty else {
            return String(format: L.t("macScreen.actions.unknownDeviceNoneListed", "No device is named “%@”, and no devices are listed: sign in to cmux on both Macs and turn on Allow Mac Screen on the other Mac."), name)
        }
        return String(format: L.t("macScreen.actions.unknownDevice", "No device is named “%@”. Your devices: %@."), name, listed(devices))
    }
    private static func missingDevice(among devices: [HubDevice]) -> String {
        guard !devices.isEmpty else {
            return L.t("macScreen.actions.missingDeviceNoneListed", "Pass a device name or id. No devices are listed: sign in to cmux on both Macs and turn on Allow Mac Screen on the other Mac.")
        }
        return String(format: L.t("macScreen.actions.missingDevice", "Pass a device name or id. Your devices: %@."), listed(devices))
    }

    /// The targeted tab's viewer while it asks, waits or streams (Stop Viewing's tab).
    func viewer(_ invocation: ActionInvocation) -> MacScreenPane? {
        guard let pane = screenTab(invocation), let phase = pane.model.hub?.phase,
              phase.isPending || phase.streamingScope != nil else { return nil }
        return pane
    }

    /// The targeted tab's Screen Sharing screen, else the selected tab's, in any phase.
    func screenTab(_ invocation: ActionInvocation) -> MacScreenPane? {
        let id: String
        if let target = invocation.target ?? invocation["tab"]?.targetValue {
            guard target.kind == .tab else { return nil }
            id = target.id
        } else {
            guard let selected = selectedTab() else { return nil }
            id = selected
        }
        guard let key = providerKey(id, invocation.targetMachineID) else { return nil }
        return pages.tab(key)?.pane
    }

    private static func isPerson(_ invocation: ActionInvocation) -> Bool {
        invocation.origin == .user && !invocation.viaControlSocket && ActionRunScope.isPersonsAction()
    }

    /// The opened tab connects to view at once, the way a person's open does: a person opened it, or the caller
    /// asked with `autoconnect` (default off), so `cmux action run macScreen.open --device X --autoconnect` reaches
    /// the hub with no Connect click. Both gates take it: the requested scope (`record(forDevice:requesting:)`) and
    /// the confirmed record `makeHubPane` resumes it on. Leo, 2026-11-16: "At least like Linux to Mac".
    static func connects(_ invocation: ActionInvocation) -> Bool {
        isPerson(invocation) || autoconnects(invocation)
    }

    /// `autoconnect: true`, as the CLI sends a bare `--autoconnect`, or `"true"` (`--autoconnect=true`, `--arg`).
    static func autoconnects(_ invocation: ActionInvocation) -> Bool {
        guard let value = invocation["autoconnect"] else { return false }
        return value.boolValue ?? (value.stringValue?.lowercased() == "true")
    }
    private static var noPane: String { L.t("macScreen.actions.noPane", "Choose a pane or tab to open Screen Sharing.") }
    private static var noViewer: String { L.t("macScreen.actions.noViewer", "Choose a Screen Sharing tab to stop viewing.") }
}

/// A machine `cmux device list` lists, as Screen Sharing's refusal reads it: its name and, when the list offers it no
/// screen, why (the row's `screen.reason`, decided in Rust by `cmux_device_kind::screen::offer`).
public struct MacScreenListedDevice: Equatable, Sendable {
    public var name: String
    /// `offline`, `no-desktop`, `phone` or `unknown`; nil when the list offers View but Screen Sharing lists no such
    /// device (it never registered with the device hub).
    public var noScreenReason: String?

    public init(name: String, noScreenReason: String?) {
        self.name = name
        self.noScreenReason = noScreenReason
    }

    /// A `cmux device list` row by its `screen` offer: nil for a row with none (a person's login, not a machine).
    public init?(name: String, screenAction: String?, reason: String?) {
        guard let screenAction else { return nil }
        self.init(name: name, noScreenReason: screenAction == "none" ? reason ?? "unknown" : nil)
    }

    /// The reason, as the clause after "offers no screen: ".
    var noScreenText: String {
        switch noScreenReason {
        case "offline": L.t("macScreen.actions.refusal.noScreen.offline", "it is offline")
        case "no-desktop": L.t("macScreen.actions.refusal.noScreen.noDesktop", "it is a server or VM with no desktop to share")
        case "phone": L.t("macScreen.actions.refusal.noScreen.phone", "an iPhone or iPad cannot share its screen")
        case nil: L.t("macScreen.actions.refusal.noScreen.notRegistered", "Screen Sharing does not list it yet; sign in to cmux on it and turn on Allow Mac Screen")
        default: L.t("macScreen.actions.refusal.noScreen.unknown", "cmux cannot tell whether it has a desktop to share")
        }
    }
}

/// cmux Remote's worker as Stop Sharing This Mac sees it: whether it runs, and how to end the session it hosts.
public struct MacScreenWorkerSession {
    let running: @MainActor () -> Bool
    let stop: @MainActor () async throws -> Void

    public init(running: @escaping @MainActor () -> Bool, stop: @escaping @MainActor () async throws -> Void) {
        self.running = running
        self.stop = stop
    }

    /// No worker: a build without cmux Remote, and tests.
    public static var none: MacScreenWorkerSession { MacScreenWorkerSession(running: { false }, stop: {}) }
}
