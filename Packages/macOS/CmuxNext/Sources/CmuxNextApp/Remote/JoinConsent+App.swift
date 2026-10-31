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
        let cli = (try? DaemonLauncher.resolveBinary(bundle: .main, environment: ProcessInfo.processInfo.environment))
            .map { HostCLI(binary: $0, environment: SSHService.environment) }
        #if DEBUG
        let fixtures = services.debugFixtures
        #endif
        return JoinConsentServices(
            status: {
                #if DEBUG
                if let fixture = fixtures.joinStatus { return fixture }
                #endif
                guard let data = await cli?.json(["acp", "host", "join", "--status", "--json"], deadline: .seconds(10), label: "join status")
                else { return nil }
                return JoinStatus.parse(data)
            },
            openLine: { [weak services] in
                #if DEBUG
                if fixtures.joinStatus != nil { return fixtures.joinLine }
                #endif
                guard let services, let environment = QuitAgents.environment(services),
                      let line = await AcpmuxPersonLine.open(environment) else { return nil }
                return JoinConsentPersonLine(line)
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

/// acpmux's machine consent, one per OS user and shared by every app build:
/// `<the user's home>/.acpmux/machine-consent/{enrolled.json,consent.json,refusal.json}`. A change there
/// (the folder made at the first join, a file made, replaced, rewritten or removed) is one element, so the
/// app asks acpmux again (`machine_consent_get`); the files are never read for a decision. Event-driven:
/// the folder through ``FolderChanges`` (through a parent until it exists) and each file through its own
/// vnode watch, armed again after each folder change. Both are armed in ``events(armed:)`` itself, before
/// it returns and before its watch loop starts (``FolderChanges/events()`` returns once it is registered, on the folder or
/// its nearest existing parent): the folder's first, then the files', then `armed` runs, then the stream
/// yields once. So a change made from then on (the folder made, a file written) is seen by a watch, and
/// one made while they armed is read by that first ask. Ends when the consumer stops iterating.
nonisolated struct MachineConsentChanges: Sendable {
    static let files = ["enrolled.json", "consent.json", "refusal.json"]

    /// The folder, from the user's own password entry (`getpwuid(geteuid())`), never `HOME` or
    /// `ACPMUX_HOME`, which a launch can set to anything.
    static var folder: URL? {
        guard let entry = getpwuid(geteuid()), let home = entry.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: home), isDirectory: true)
            .appending(path: ".acpmux/machine-consent", directoryHint: .isDirectory)
    }

    let folder: URL

    /// - Parameter armed: Runs once both watches are armed, before the first element and before the watch
    ///   loop starts (the handshake a caller can make a change in).
    func events(armed: () -> Void = {}) async -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let folder = folder
        // Armed here, in this order: the folder (FolderChanges arms in events(), not in its loop), then the
        // files, then one element, so nothing made or replaced while they armed is missed.
        let folderChanges = await FolderChanges(folders: [folder]).events()
        let first = Self.watchFiles(in: folder, continuation)
        armed()
        continuation.yield()
        // task-owner: the stream's watch loop; cancelled when the consumer stops iterating
        let loop = Task.detached(priority: .utility) {
            var watches = first
            // wakeup-allow: each pass waits for one file-system event in the consent folder, never polls
            for await _ in folderChanges {
                watches.forEach { $0.cancel() }
                watches = Self.watchFiles(in: folder, continuation)
                continuation.yield()
            }
            watches.forEach { $0.cancel() }
            continuation.finish()
        }
        continuation.onTermination = { _ in loop.cancel() }
        return stream
    }

    /// A watch on each consent file that exists now: a write in place, a replace or a removal yields.
    private static func watchFiles(in folder: URL, _ continuation: AsyncStream<Void>.Continuation) -> [any DispatchSourceFileSystemObject] {
        files.compactMap { name in
            let fd = open(folder.appending(path: name).path, O_EVTONLY)
            guard fd >= 0 else { return nil }
            // DispatchSource for file watching: no Foundation async equivalent (idle-wakeups.md).
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete, .attrib],
                                                                   queue: .global(qos: .utility))
            source.setEventHandler { continuation.yield() }
            source.setCancelHandler { close(fd) }
            source.resume()
            return source
        }
    }
}
