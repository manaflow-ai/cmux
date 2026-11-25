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
import LocalAuthentication

/// This Mac's join consent in the app (contract §5): the join status from the bundled cmux-tui's acpmux
/// (`acp host join --status --json`), and the consent record over a person-proof acpmux line
/// (`_acpmux/machine_consent_get` and `_set`, under `machine-consent-v1`). acpmux changes the record only
/// for a connection proven as the person on its local socket (the Full access pattern); no command line
/// can, so the app calls it directly.
extension JoinConsentServices {
    static let askShownKey = "cmux.join.consentAskShown"

    static func app(_ services: AppServices) -> JoinConsentServices {
        let cli = SSHService.bundledCLI?.onPlatform(of: services.environment.terminalEnvironment)
        #if DEBUG
        let fixtures = services.debugFixtures
        #endif
        return JoinConsentServices(
            status: {
                #if DEBUG
                if let fixture = fixtures.joinStatus { return fixture }
                #endif
                return (await cli?.json(["acp", "host", "join", "--status", "--json"], deadline: .seconds(10), label: "join status")).flatMap(JoinStatus.parse)
            },
            enabled: { [weak services] in services?.settings?.snapshot.machineJoin == true },
            settingsEpoch: { [weak services] in services?.settings?.loadCount ?? -1 },
            confirmOwner: { surface in
                // Touch ID or the login password, every grant (LocalDeviceOwnerAuthenticator, as the
                // password store's reveal); a Mac that can't ask grants nothing.
                var unavailable: NSError?
                guard LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &unavailable) else { return .unavailable }
                return await LocalDeviceOwnerAuthenticator().authenticate(reason: JoinConsentStrings.confirmReason(surface)) ? .confirmed : .cancelled
            },
            askShown: { UserDefaults.standard.bool(forKey: askShownKey) },
            markAskShown: { UserDefaults.standard.set(true, forKey: askShownKey) },
            open: { [weak services] in
                #if DEBUG
                if fixtures.joinStatus != nil { return .line(fixtures.joinLine) }
                #endif
                return await JoinConsentPersonLine.open(services.flatMap(QuitAgents.environment))
            })
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

    static func open(_ environment: AcpmuxEnvironment?) async -> JoinConsentOpen {
        guard let environment else { return .failed(.notRunning(path: nil)) }
        return switch await AcpmuxPersonLine.connectEnrolling(environment) {
        case .success(let line): .line(JoinConsentPersonLine(line))
        case .failure(.noSocket(let path)): .failed(.notRunning(path: path))
        case .failure(.refused(let why)): .failed(.refused(why))
        case .failure(.noAnswer): .failed(.noAnswer)
        case .failure(.olderDaemon(let path)): .failed(.olderDaemon(path: path))
        }
    }
    var isPerson: Bool { line.isPerson }
    var supportsConsent: Bool { line.capabilities.contains(Self.capability) }
    var notProven: JoinConsentUnread? { line.notPersonReason.map { .notProven(foreignPath: line.foreignPeerPath, why: $0.description) } }
    var readError: String? { line.lastError }

    func read() async -> JoinConsentRecord? {
        (await line.call("_acpmux/machine_consent_get", [:])).flatMap(JoinConsentRecord.parse)
    }

    func set(_ surface: JoinConsentSurface, granted: Bool, ticket: JoinConsentGrantTicket?) async -> JoinConsentRecord? {
        // SECURITY: a grant's ticket is checked on the line's queue, under the gate's lock, as it writes.
        var gate: (@Sendable (() -> Void) -> Bool)?
        if let ticket { gate = { @Sendable bytes in ticket.write(bytes) } }
        return (await line.call("_acpmux/machine_consent_set", ["surface": surface.rawValue, "granted": granted], through: gate))
            .flatMap(JoinConsentRecord.parse)
    }

    func close() { line.close() }
}

extension JoinConsentModel {
    /// The model with its one-time sheet's panel, made on the first show. The app's activation loop reads
    /// it again each time the app comes forward (AppDelegate), so a refusal acpmux recorded meanwhile shows
    /// the sheet.
    static func app(_ services: AppServices) -> JoinConsentModel {
        let model = JoinConsentModel(services: .app(services))
        #if DEBUG
        model.fixtureActive = { [fixtures = services.debugFixtures] in fixtures.joinStatus != nil }
        #endif
        var panel: JoinConsentAskPanel?
        let person = PersonInputCheck(sources: services.personInput.sources)
        model.present = { [weak model] shown in
            guard let model else { return }
            if shown, panel == nil {
                let made = JoinConsentAskPanel(model: model)
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

    /// Follows the Labs switch (a change drops what was read at once and reads again; turning it on stops
    /// a Mac Screen session until a read allows it) and, while it is on, acpmux's machine consent folder
    /// (``MachineConsentChanges``), where a join, a consent change or a refusal lands: each burst of
    /// changes there is one `machine_consent_get`, never a read of the files. Event-driven, never a poll.
    /// A change is taken at once, never behind a read still running. Everything ends with the model
    /// (``JoinConsentModel/following``), and the folder watch also when the switch turns off.
    func follow(settings: SettingsController) {
        Self.invalidateGrants(grantGate, onEveryLoadOf: settings)
        // task-owner: the model's `following`, cancelled with it; one read per Labs change or folder burst
        following = Task { [weak self, weak settings] in
            var watch: Task<Void, Never>?
            var reading: Task<Void, Never>?
            defer {
                watch?.cancel()
                reading?.cancel()
            }
            var last: Bool?
            guard let settings else { return }
            for await on in ObservationStream({ settings.snapshot.machineJoin }) {
                guard let self, !Task.isCancelled else { return }
                watch?.cancel()
                watch = nil
                if let last, last != on {
                    featureSwitched()
                    reading?.cancel()
                    reading = Task { [weak self] in await self?.refresh() }
                }
                last = on
                guard on, let folder = MachineConsentChanges.folder else { continue }
                watch = Task { [weak self] in
                    for await _ in await MachineConsentChanges(folder: folder).events() {
                        guard let self, !Task.isCancelled else { return }
                        await refresh()
                    }
                }
            }
        }
    }

    /// SECURITY: every settings load (the Labs switch moves only through one) invalidates the grant gate as
    /// it happens, in the load itself (``SettingsController/onEveryLoad(_:)``, on the main actor, before the
    /// load changes anything), never behind a task: a grant the line checks on its own queue right after a
    /// load is already stale. Every load, so a second load right after is caught too. Ends with the settings.
    static func invalidateGrants(_ gate: JoinConsentGrantGate, onEveryLoadOf settings: SettingsController) {
        settings.onEveryLoad { gate.invalidate() }
    }

    /// Mac Screen's gate (``MacScreenHubHost/consentGate``): a fresh read, then what it allows.
    func macScreenGate(_ ticket: SessionTicket) async -> Bool {
        guard enabled else { return true }
        // SECURITY: a capture fixture (debug.join_consent) never authorizes a live session.
        // Checked again after the read: a fixture set while it ran never authorizes either.
        if fixtureActive() { return false }
        let allowed = await allowsMacScreen(control: ticket.scope == .full, requester: ticket.peer.name)
        return allowed && !fixtureActive()
    }

    /// What the last read allows a running Mac Screen session of `scope`.
    func macScreenPermits(_ scope: SessionScope) -> Bool {
        guard enabled else { return true }
        return !fixtureActive() && permitsMacScreen(control: scope == .full)
    }
}

extension MachineConsentChanges {
    /// acpmux's consent folder, from the user's password entry (`getpwuid`), never `HOME` or `ACPMUX_HOME`.
    static var folder: URL? {
        guard let home = getpwuid(geteuid())?.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: home), isDirectory: true).appending(path: ".acpmux/machine-consent", directoryHint: .isDirectory)
    }
}
