import CmuxNextActions
import CmuxNextDaemon
import CmuxNextWindowRules
import Foundation

/// Target resolution for room handlers. Rooms live on the local daemon.
extension AppActionContext {
    var roomStore: DaemonStore { services.machines.local.store }

    func requireRooms() throws {
        guard services.machines.local.supports(DaemonCapability.profiles.rawValue) else {
            throw ActionFailure(message: services.machines.local.missingCapabilityMessage(DaemonCapability.profiles.rawValue))
        }
    }

    /// The targeted room (target, `room` argument), else the active
    /// window's room.
    func room(_ invocation: ActionInvocation) throws -> ProfileModel {
        if let target = invocation.target, target.kind == .profile { return try room(named: target.id) }
        if let room = try optionalRoom(invocation["space"]) { return room }
        let current = activeWindow?.state.profileID ?? .defaultProfile
        guard let room = roomStore.profile(current) else { throw ActionFailure.invalidTarget(RoomStrings.noRoom(current.rawValue)) }
        return room
    }

    /// The room an argument names: a target, an id, or a name (the CLI
    /// accepts `--arg room=Work`). Nil when the argument is absent.
    func optionalRoom(_ value: ActionValue?) throws -> ProfileModel? {
        guard let value else { return nil }
        if let target = value.targetValue { return try room(named: target.id) }
        guard let text = value.stringValue, !text.isEmpty else { return nil }
        return try room(named: text)
    }

    /// By id, else by name folded for case and diacritics (the folding is Foundation's; the lookup
    /// is cmux-window-rules `targets::named`).
    private func room(named text: String) throws -> ProfileModel {
        let rooms = roomStore.profiles
        let fold = { (name: String) in name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let candidates = rooms.map { WindowRules.Named(id: $0.id.rawValue, folded: fold($0.name)) }
        guard let index = WindowRules().named(text, folded: fold(text), among: candidates), rooms.indices.contains(index) else {
            throw ActionFailure.notFound(RoomStrings.noRoom(text))
        }
        return rooms[index]
    }
}

/// `space.setDefaults` arguments: `cwd` (an absolute directory; `~` and `~user` are expanded
/// here) and `env` (a JSON object of strings). A named argument replaces its field and an empty
/// one clears it; a field the run does not name keeps the space's value. The rule is Rust's
/// (cmux-window-rules `workspaces::defaults_patch`), which also refuses a value that is not text
/// or a relative `cwd`.
enum RoomDefaultsArguments {
    /// Whether the run names `cwd` or `env`, even empty.
    static func names(_ invocation: ActionInvocation) -> Bool {
        invocation["cwd"] != nil || invocation["env"] != nil
    }

    /// The fields a run names, parsed: nil leaves a field as the space has it. Nonisolated: the
    /// defaults run applies it off the main actor, to the defaults the daemon holds.
    nonisolated struct Patch: Sendable, Equatable {
        /// `.some(nil)` clears the directory.
        var cwd: String??
        var env: [String: String]?

        /// Clear Space Terminal Defaults…: both fields cleared.
        static let clear = Patch(cwd: .some(nil), env: [:])

        /// `current` with the named fields replaced.
        func applied(to current: ProfileDefaults?) -> ProfileDefaults {
            var defaults = current ?? ProfileDefaults()
            if let cwd { defaults.cwd = cwd }
            if let env { defaults.env = env }
            return defaults
        }
    }

    /// The run's named fields; throws on a value that is not text or a relative `cwd`.
    static func patch(_ invocation: ActionInvocation) throws -> Patch {
        let text = { (name: String) -> String?? in invocation[name].map { $0.stringValue } }
        // Expanding `~` and `~user` is a lookup of the user's home: Foundation's, as before.
        let cwd = text("cwd").map { $0.map { ($0.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath } }
        switch WindowRules().spaceDefaults(cwd: cwd, env: text("env")) {
        case .success(let patch)?:
            let cwd: String?? = switch patch.cwd {
            case nil: nil
            case .clear?: .some(nil)
            case .set(let path)?: .some(path)
            }
            return Patch(cwd: cwd, env: patch.env)
        case .failure(.defaultsMustBeText)?, nil: throw ActionFailure.invalidTarget(RoomStrings.defaultsMustBeText)
        case .failure(.cwdMustBeAbsolute)?: throw ActionFailure.invalidTarget(RoomStrings.cwdMustBeAbsolute)
        case .failure(.envMustBeObject)?: throw ActionFailure.invalidTarget(RoomStrings.envMustBeObject)
        }
    }
}
