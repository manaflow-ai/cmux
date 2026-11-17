public import CmuxNextActions
import CmuxNextAgentActivity
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
    let worker: MacScreenWorkerSession
    let startedBy: (ActionInvocation) -> String?

    /// - Parameters:
    ///   - worker: cmux Remote's worker, the host of this Mac's session in a build that bundles cmux Remote.
    ///   - startedBy: the name of the agent an automation run came from, shown on a tab it starts viewing;
    ///     nil (the default) is ``agentName(_:)``, which tests replace.
    public init(pages: MacScreenPages, selectedTab: @escaping () -> String?,
                providerKey: @escaping (String, String?) -> String?,
                open: @escaping (() throws -> MacScreenRecord, ActionInvocation, Bool) throws -> Void,
                refusal: @escaping (any Error) -> Void, worker: MacScreenWorkerSession = .none,
                startedBy: ((ActionInvocation) -> String?)? = nil) {
        self.pages = pages
        self.selectedTab = selectedTab
        self.providerKey = providerKey
        self.open = open
        self.refusal = refusal
        self.worker = worker
        self.startedBy = startedBy ?? Self.agentName
    }

    /// - Parameter paletteRows: Adds a root palette provider: one "Screen Sharing: <device>" row per device.
    public func bind(into registry: ActionRegistry, paletteRows: ((AsyncPaletteProvider) -> Void)? = nil) {
        paletteRows?(pages.paletteProvider(registry: registry))
        registry.bindEffect("macScreen.open", effect: { invocation in
            if let target = invocation.target, target.kind != .pane && target.kind != .tab { return .refused(Self.noPane) }
            do { try open({ try Self.record(invocation, pages: pages, startedBy: startedBy) }, invocation, Self.isPerson(invocation)) }
            catch { refusal(error) }
            // An agent's start is its own tab's, prepared in this turn: one no tab took (no pane) never confirms a later one.
            pages.pendingStarters.removeAll()
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

    static func record(_ invocation: ActionInvocation, pages: MacScreenPages,
                       startedBy: (ActionInvocation) -> String? = { _ in nil }) throws -> MacScreenRecord {
        try record(invocation, pages: pages, devices: pages.viewableDevices, startedBy: startedBy)
    }

    /// `device` is the hub's device id or, from the CLI and agents, a device name (the Mac's Computer Name) among
    /// `devices`, the devices the home page lists. Names resolve here, at the action boundary: records and
    /// `MacScreenPages.record(forDevice:)` take only ids. No `device` opens the home page.
    ///
    /// A person's open asks for View Only when its tab shows. An agent's or the CLI's open of one of the person's
    /// own devices asks for `scope` (View Only unless `full`) at once and names `startedBy`'s agent on the tab, unless
    /// Only Your Click Starts Viewing a Screen is on (Leo, 2026-11-17: "why should it get held only be aperson's
    /// click? i dont like that"). Any other automation open waits at the Connect card for the person.
    static func record(_ invocation: ActionInvocation, pages: MacScreenPages, devices: [HubDevice],
                       startedBy: (ActionInvocation) -> String? = { _ in nil }) throws -> MacScreenRecord {
        guard let value = invocation["device"] else { return MacScreenRecord(macID: nil) }
        guard let text = value.stringValue else { throw ActionFailure(message: missingDevice(among: devices)) }
        let id = try deviceID(named: text, among: devices)
        if isPerson(invocation) { return pages.record(forDevice: id, requesting: .view) }
        guard pages.agentMayStartViewing(id, among: devices) else { return pages.record(forDevice: id) }
        return pages.record(forDevice: id, requesting: scope(invocation), startedBy: MacScreenStarter(name: startedBy(invocation)))
    }

    /// The agent `invocation` came from, as the person knows it: the title of the agent session that sent it
    /// (`callerAgentSession`, its acpmux lane: the name its chat and Agent Activity show), else the calling app.
    /// Nil names none (a terminal's or a script's CLI call: `callerTerminal` is an id, not a name), and the tab
    /// says "an agent".
    static func agentName(_ invocation: ActionInvocation) -> String? {
        invocation.callerAgentSession.flatMap { AgentLaneStore.shared.lane($0)?.title } ?? invocation.callerApp
    }

    /// `scope`: `full` asks for Full Control; `view`, or none, View Only (the catalog refuses any other value).
    static func scope(_ invocation: ActionInvocation) -> SessionScope {
        invocation["scope"]?.stringValue?.lowercased() == "full" ? .full : .view
    }

    /// The hub id `text` names: an id as is (listed or not, as before names resolved), else the one device whose
    /// name matches case-insensitively, else the one whose name matches ignoring punctuation and spacing too
    /// ("mac-mini" for "Mac Mini", "leos-mac" for "Leo’s Mac"), so a `cmux device list` name finds its Mac.
    /// An empty, unknown or ambiguous name fails with the devices it could name, as "name (id)".
    static func deviceID(named text: String, among devices: [HubDevice]) throws -> String {
        if let id = MacScreenRecord.normalizedDeviceID(text) { return id }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ActionFailure(message: missingDevice(among: devices)) }
        for key: (String) -> String in [Self.folded, Self.slug] {
            let wanted = key(name)
            guard !wanted.isEmpty else { continue }
            let matches = devices.filter { key($0.name) == wanted }
            if matches.count == 1, let match = matches.first { return match.id }
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
    private static var noPane: String { L.t("macScreen.actions.noPane", "Choose a pane or tab to open Screen Sharing.") }
    private static var noViewer: String { L.t("macScreen.actions.noViewer", "Choose a Screen Sharing tab to stop viewing.") }
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
