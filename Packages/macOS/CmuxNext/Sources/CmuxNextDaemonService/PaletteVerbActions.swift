public import CmuxNextActions
public import CmuxNextDaemon
import CmuxNextCloud
public import CmuxNextWakeups
public import Foundation

/// What the four CLI-verb palette rows read from the app (``PaletteVerbActions``); `AppServices` forwards.
@MainActor
public protocol PaletteVerbHost: AnyObject {
    /// This Mac's daemon, which holds spaces and their follows.
    var paletteLocalDaemon: DaemonService { get }
    /// The bundled `cmux` CLI.
    var paletteCLI: BundledExecutable { get }
    /// Off-main file work (the Cloud secret index read).
    var paletteWork: BackgroundWork { get }
    /// Throws why when this Mac's daemon has no spaces.
    func paletteRequireSpaces() throws
    /// The space `invocation` names (its target, `space`, else the active window's); throws why when there is none.
    func paletteRoom(_ invocation: ActionInvocation) throws -> ProfileID
    /// The pane `invocation` names, else the focused one; nil when there is none (the lookup said why).
    func palettePane(_ invocation: ActionInvocation) -> PaneModel?
    /// The daemon that holds `pane`.
    func paletteDaemon(for pane: PaneModel) -> DaemonService
    /// `pane`'s resource path; nil when its daemon cannot name it yet.
    func paletteResourcePath(of pane: PaneModel) -> PaneResourcePath?
    /// Runs `cmux customize library reset` with the Settings card's environment.
    func paletteResetLibrary(_ cli: URL) async throws
    /// Why `error` failed, in the person's words.
    func paletteMessage(_ error: any Error) -> String
    /// Shows `message` in the active window's toast.
    func paletteToast(_ message: String, duration: Duration)
}

/// Step B of the palette rows for four CLI verbs (cmux#46170); each row runs what its verb runs:
/// - Reset Customization Library (`customize.library.reset`): `cmux customize library reset`.
/// - Follow Session in Space… (`space.followSession`): `set-profile-follows` with the session added to the ones the
///   space follows, read from the daemon when it runs (`list-personal`), never the mirror, which lags a reply.
/// - Show Terminal in New Tab… (`terminal.project`): `terminal.project` into the target pane, after its last tab.
/// - Remove Cloud Secret… (`cloud.secret.remove`): `cmux cloud secret rm`, which deletes the Keychain item and its
///   index entry under the index lock. Destructive: the app asks first (``secretRemovePrompt(_:)``).
@MainActor
public struct PaletteVerbActions {
    let host: any PaletteVerbHost

    /// - Parameter host: The app (`AppServices`).
    public init(host: any PaletteVerbHost) { self.host = host }

    /// Binds Reset Customization Library, Follow Session in Space… and Show Terminal in New Tab…, and the
    /// `personalSessions` picker.
    public func bind(into registry: ActionRegistry) {
        let host = host
        let noCLI: @MainActor () -> String? = { host.paletteCLI.known == nil ? PaletteVerbStrings.noCLI : nil }
        registry.bindEffect("customize.library.reset", unavailable: noCLI, effect: { _ in Self.resetLibrary(host) })
        registry.bindEffect("space.followSession", effect: { invocation in Self.follow(invocation, host) })
        registry.bindEffect("terminal.project", effect: { invocation in Self.project(invocation, host) })
        let other = registry.argumentSuggestions
        registry.argumentSuggestions = { source in
            guard source == "personalSessions" else { return other?(source) ?? [] }
            return host.paletteLocalDaemon.store.personal.sessions.map {
                let title = Self.sessionTitle($0)
                return ActionEnumCase(value: $0.id, title: title, subtitle: $0.machineName == title ? nil : $0.machineName)
            }
        }
    }

    /// Binds Remove Cloud Secret… and its `cloudSecrets` picker; CloudHandlers calls it before its unavailable sweep.
    public func bindSecretRemove(into registry: ActionRegistry) {
        let host = host
        let accounts = CloudSecretAccounts(work: host.paletteWork)
        registry.bindEffect("cloud.secret.remove", unavailable: { host.paletteCLI.known == nil ? PaletteVerbStrings.noCLI : nil }, effect: { invocation in
            guard let (name, scope) = Self.secretAccount(invocation["secret"]?.stringValue) else { return .refused(PaletteVerbStrings.secretInvalid) }
            let arguments = ["--json", "cloud", "secret", "rm", name] + (scope == "*" ? [] : ["--repo", scope])
            return .applied(result: {
                defer { accounts.refresh() }
                return await Self.runCLI(host, arguments, done: PaletteVerbStrings.secretRemoved(name), failed: PaletteVerbStrings.secretRemoveFailed)
            })
        })
        let other = registry.argumentSuggestions
        registry.argumentSuggestions = { source in
            guard source == "cloudSecrets" else { return other?(source) ?? [] }
            accounts.refresh()
            return accounts.names.compactMap { account in
                Self.secretAccount(account).map { ActionEnumCase(value: account, title: $0.name, subtitle: $0.scope == "*" ? nil : $0.scope, symbol: "key") }
            }
        }
    }

    // MARK: The rows

    static func resetLibrary(_ host: any PaletteVerbHost) -> ActionEffect {
        .applied(result: {
            guard let cli = await host.paletteCLI.resolve() else { return .failure(ActionWorkFailure(PaletteVerbStrings.noCLI)) }
            do { try await host.paletteResetLibrary(cli) } catch {
                return shownFailure(host, PaletteVerbStrings.libraryResetFailed(host.paletteMessage(error)))
            }
            host.paletteToast(PaletteVerbStrings.libraryReset, duration: .seconds(8))
            return .success([:])
        })
    }

    static func follow(_ invocation: ActionInvocation, _ host: any PaletteVerbHost) -> ActionEffect {
        let room: ProfileID
        do {
            try host.paletteRequireSpaces()
            room = try host.paletteRoom(invocation)
        } catch { return .refused(host.paletteMessage(error)) }
        guard let picked = invocation["session"]?.stringValue?.trimmingCharacters(in: .whitespaces), !picked.isEmpty else {
            return .refused(PaletteVerbStrings.sessionRequired)
        }
        // The registry id, or the name the picker titles it with.
        let sessions = host.paletteLocalDaemon.store.personal.sessions
        let session = sessions.first(where: { $0.id == picked })?.id ?? sessions.first(where: { sessionTitle($0) == picked })?.id ?? picked
        return host.paletteLocalDaemon.commandEffect("set-profile-follows") { connection in
            let follows = try await connection.listPersonal().profiles.first(where: { $0.id == room })?.follows ?? []
            guard !follows.contains(session) else { return }
            _ = try await connection.request(SetProfileFollowsRequest(profile: room, sessionIDs: follows + [session]))
        }
    }

    static func project(_ invocation: ActionInvocation, _ host: any PaletteVerbHost) -> ActionEffect {
        guard let terminal = invocation["terminal"]?.stringValue?.trimmingCharacters(in: .whitespaces), !terminal.isEmpty else {
            return .refused(PaletteVerbStrings.terminalRequired)
        }
        guard let pane = host.palettePane(invocation) else { return .done } // the lookup said why
        guard let path = host.paletteResourcePath(of: pane) else { return .refused(PaletteVerbStrings.paneHasNoPath) }
        let index = pane.tabs.count
        return host.paletteDaemon(for: pane).commandEffect("terminal.project") { connection in
            _ = try await connection.projectTerminal(ResourceID(rawValue: terminal), into: path, index: index)
        }
    }

    // MARK: Helpers

    /// The confirmation Remove Cloud Secret… asks (title, body, button); nil for a value that names no secret, which
    /// the handler refuses with why.
    public static func secretRemovePrompt(_ invocation: ActionInvocation) -> (title: String, body: String, button: String)? {
        guard let (name, scope) = secretAccount(invocation["secret"]?.stringValue) else { return nil }
        return (PaletteVerbStrings.removeSecretTitle(scope == "*" ? name : "\(scope)/\(name)"), PaletteVerbStrings.removeSecretBody,
                PaletteVerbStrings.removeSecret)
    }

    /// A picked index account (`SCOPE/NAME`, scope `*` or `OWNER/REPO`) or a typed bare `NAME` (every repo): its name
    /// and scope; nil when the name is not a secret name.
    static func secretAccount(_ value: String?) -> (name: String, scope: String)? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        let split = value.lastIndex(of: "/")
        let scope = split.map { String(value[..<$0]) } ?? "*"
        let name = split.map { String(value[value.index(after: $0)...]) } ?? value
        guard !scope.isEmpty, CloudMachineSecrets.isName(name) else { return nil }
        return (name, scope)
    }

    static func sessionTitle(_ record: SessionRecord) -> String {
        [record.sessionName, record.machineName].compactMap { $0?.isEmpty == false ? $0 : nil }.first ?? record.id
    }

    static func runCLI(_ host: any PaletteVerbHost, _ arguments: [String], done: String,
                       failed: (String) -> String) async -> Result<[String: ActionResultValue], ActionWorkFailure> {
        guard let cli = await host.paletteCLI.resolve() else { return .failure(ActionWorkFailure(PaletteVerbStrings.noCLI)) }
        guard let result = await BundledCLIRun.run(cli, arguments, timeout: .seconds(30)) else {
            return shownFailure(host, failed(PaletteVerbStrings.didNotFinish))
        }
        guard result.status == 0 else {
            let why = BundledCLIRun.lastLine(result.stderr) ?? BundledCLIRun.lastLine(result.stdout) ?? "exit \(result.status)"
            return shownFailure(host, failed(why))
        }
        host.paletteToast(done, duration: .seconds(8))
        return .success(["output": .string(String(decoding: result.stdout, as: UTF8.self))])
    }

    static func shownFailure(_ host: any PaletteVerbHost, _ message: String) -> Result<[String: ActionResultValue], ActionWorkFailure> {
        host.paletteToast(message, duration: .seconds(12))
        var failure = ActionWorkFailure(message)
        failure.shown = true // the toast already says it
        return .failure(failure)
    }
}

/// This build's Cloud secret index accounts (names and scopes, never values) for the `cloudSecrets` picker: read off
/// the main thread, the list answering the last read.
@MainActor
final class CloudSecretAccounts {
    private let work: BackgroundWork
    private(set) var names: [String] = []
    private var reading = false

    init(work: BackgroundWork) {
        self.work = work
        refresh()
    }

    func refresh() {
        guard !reading else { return }
        reading = true
        let work = work
        Task { [weak self] in // task-owner: self; one bounded file read at a time
            let file = try? await work.run(.userVisible, mayBlock: .files) { CloudMachineSecrets.read(CloudMachineSecrets.indexURL().path) }
            guard let self else { return }
            if let index = file.flatMap(CloudMachineSecrets.index(from:)) { names = index.keys.sorted() }
            reading = false
        }
    }
}

enum PaletteVerbStrings {
    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "CatalogRequests", bundle: .localizedModule)
    }

    static var noCLI: String { text("paletteVerb.noCLI", "This build does not include the cmux CLI.") }
    static var didNotFinish: String { text("paletteVerb.didNotFinish", "it did not finish in time") }
    static var libraryReset: String { text("paletteVerb.libraryReset", "Every customization library entry is off.") }
    static func libraryResetFailed(_ why: String) -> String {
        String(format: text("paletteVerb.libraryResetFailed", "Could not reset the customization library: %@"), why)
    }
    static var sessionRequired: String { text("paletteVerb.sessionRequired", "Pick the session the space should follow.") }
    static var terminalRequired: String { text("paletteVerb.terminalRequired", "Pick the terminal to show.") }
    static var paneHasNoPath: String { text("paletteVerb.paneHasNoPath", "This pane cannot show another terminal yet. Update cmux, then try again.") }
    static var secretInvalid: String { text("paletteVerb.secretInvalid", "Pick a Cloud secret to remove.") }
    static func secretRemoved(_ name: String) -> String { String(format: text("paletteVerb.secretRemoved", "Removed the Cloud secret %@."), name) }
    static func secretRemoveFailed(_ why: String) -> String {
        String(format: text("paletteVerb.secretRemoveFailed", "Could not remove the Cloud secret: %@"), why)
    }
    static func removeSecretTitle(_ name: String) -> String { String(format: text("paletteVerb.removeSecretTitle", "Remove the Cloud secret %@?"), name) }
    static var removeSecretBody: String {
        text("paletteVerb.removeSecretBody", "Its value is deleted from this Mac's Keychain, and Cloud machines no longer get it.")
    }
    static var removeSecret: String { text("paletteVerb.removeSecret", "Remove") }
}
