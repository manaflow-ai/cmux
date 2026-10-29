import AppKit
import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDevices
import CmuxNextRemote
import CmuxNextCompat
import CmuxNextServer
import CmuxNextSettings
import CmuxNextWakeups
import Foundation

/// This Mac's join consent in the app (contract §5): the join status from the bundled cmux-tui's acpmux
/// (`acp host join --status --json`), and the consent record over a person-proof acpmux line
/// (`_acpmux/machine_consent_get` and `_set`, under `machine-consent-v1`). acpmux changes the record only
/// for a connection proven as the person on its local socket (the Full access pattern); no command line
/// can, so the app calls it directly.
extension JoinConsentServices {
    static let askShownKey = "cmux.join.consentAskShown"

    static func app(_ services: AppServices) -> JoinConsentServices {
        let cli = (try? DaemonLauncher.resolveBinary(bundle: .main, environment: ProcessInfo.processInfo.environment))
            .map { HostCLI(binary: $0, environment: SSHService.environment) }
        return JoinConsentServices(
            status: {
                #if DEBUG
                if let fixture = DebugJoinConsent.status { return fixture }
                #endif
                guard let data = await cli?.json(["acp", "host", "join", "--status", "--json"], deadline: .seconds(10), label: "join status")
                else { return nil }
                return JoinStatus.parse(data)
            },
            openLine: { [weak services] in
                #if DEBUG
                if DebugJoinConsent.status != nil { return DebugJoinConsent.line }
                #endif
                guard let services, let environment = QuitAgents.environment(services),
                      let line = await AcpmuxPersonLine.open(environment) else { return nil }
                return JoinConsentPersonLine(line)
            },
            enabled: { [weak services] in services?.settings?.snapshot.machineJoin == true },
            askShown: { UserDefaults.standard.bool(forKey: askShownKey) },
            markAskShown: { UserDefaults.standard.set(true, forKey: askShownKey) })
    }
}

/// ``JoinConsentLine`` over the app's ``AcpmuxPersonLine``.
@MainActor
final class JoinConsentPersonLine: JoinConsentLine {
    static let capability = "machine-consent-v1"
    private let line: AcpmuxPersonLine

    init(_ line: AcpmuxPersonLine) {
        self.line = line
    }

    var isPerson: Bool { line.isPerson }
    var supportsConsent: Bool { line.capabilities.contains(Self.capability) }

    func read() async -> JoinConsentRecord? {
        (await line.call("_acpmux/machine_consent_get", [:])).flatMap(JoinConsentRecord.parse)
    }

    func set(_ surface: JoinConsentSurface, granted: Bool) async -> JoinConsentRecord? {
        (await line.call("_acpmux/machine_consent_set", ["surface": surface.rawValue, "granted": granted])).flatMap(JoinConsentRecord.parse)
    }

    func close() { line.close() }
}

extension JoinConsentModel {
    /// The model with its one-time sheet's panel, made on the first show. The app's activation loop reads
    /// it again each time the app comes forward (AppDelegate), so a refusal acpmux recorded meanwhile shows
    /// the sheet.
    static func app(_ services: AppServices) -> JoinConsentModel {
        let model = JoinConsentModel(services: .app(services))
        var panel: JoinConsentAskPanel?
        model.present = { [weak model] shown in
            guard let model else { return }
            if shown, panel == nil {
                let made = JoinConsentAskPanel(model: model)
                let person = PersonInputCheck()
                made.isPersonEvent = { person.isPerson($0) }
                panel = made
            }
            panel?.setShown(shown)
        }
        model.redraw = { [weak model] in
            guard let model, model.ask != nil else { return }
            panel?.setShown(true)
        }
        return model
    }

    /// Follows the Labs switch (a change drops what was read and reads again; turning it on stops a Mac
    /// Screen session until a read allows it) and, while it is on, acpmux's home folder, where a join, a
    /// consent change or a refusal lands: each burst of changes there is one read. Event-driven, never a
    /// poll; both loops end with the model (the folder watch also when the switch turns off).
    func follow(_ services: AppServices, settings: SettingsController) {
        // task-owner: lives as long as the model; one read per Labs change or burst of folder changes
        Task { [weak self, weak services, weak settings] in
            var watch: Task<Void, Never>?
            defer { watch?.cancel() }
            var last: Bool?
            guard let settings else { return }
            for await on in ObservationStream({ settings.snapshot.machineJoin }) {
                guard let self else { return }
                watch?.cancel()
                watch = nil
                if let last, last != on { await featureChanged() }
                last = on
                guard on, let services, let home = QuitAgents.environment(services)?.home else { continue }
                watch = Task { [weak self] in
                    for await _ in FolderChanges(folders: [home]).events() {
                        guard let self else { return }
                        await refresh()
                    }
                }
            }
        }
    }

    /// Mac Screen's gate (``MacScreenHubHost/consentGate``): a fresh read, then what it allows.
    func macScreenGate(_ ticket: SessionTicket) async -> Bool {
        guard enabled else { return true }
        // SECURITY: a capture fixture (debug.join_consent) never authorizes a live session.
        // Checked again after the read: a fixture set while it ran never authorizes either.
        if Self.fixtureActive { return false }
        let allowed = await allowsMacScreen(control: ticket.scope == .full, requester: ticket.peer.name)
        return allowed && !Self.fixtureActive
    }

    /// What the last read allows a running Mac Screen session of `scope`.
    func macScreenPermits(_ scope: SessionScope) -> Bool {
        guard enabled else { return true }
        return !Self.fixtureActive && permitsMacScreen(control: scope == .full)
    }

    private static var fixtureActive: Bool {
        #if DEBUG
        DebugJoinConsent.status != nil
        #else
        false
        #endif
    }
}
