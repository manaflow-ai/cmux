import CmuxNextActions
import CmuxNextDaemon
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

    private func room(named text: String) throws -> ProfileModel {
        if let room = roomStore.profile(ProfileID(rawValue: text)) { return room }
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if let room = roomStore.profiles.first(where: {
            $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == folded
        }) { return room }
        throw ActionFailure.notFound(RoomStrings.noRoom(text))
    }
}

/// `space.setDefaults` arguments: `cwd` (an absolute directory, `~` expanded) and
/// `env` (a JSON object of strings). A named argument replaces its field and an
/// empty one clears it; a field the run does not name keeps the space's value, so
/// `--cwd X` alone keeps the environment. Both named and empty clears the
/// defaults; a run that names neither sets nothing (the handler asks). A value
/// that is not text, or a relative `cwd` (the socket makes a bare `--cwd` the
/// string "true"), is refused rather than clearing or setting a bad directory.
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
        try Patch(cwd: invocation["cwd"].map(directory), env: invocation["env"].map(environment))
    }

    /// The space's defaults after this run: `current` with the named fields replaced.
    static func merged(_ invocation: ActionInvocation, into current: ProfileDefaults?) throws -> ProfileDefaults {
        try patch(invocation).applied(to: current)
    }

    private static func text(_ value: ActionValue) throws -> String {
        guard let text = value.stringValue else { throw ActionFailure.invalidTarget(RoomStrings.defaultsMustBeText) }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// The directory `value` names; nil when empty (clear it).
    private static func directory(_ value: ActionValue) throws -> String? {
        let text = try text(value)
        guard !text.isEmpty else { return nil }
        let path = (text as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { throw ActionFailure.invalidTarget(RoomStrings.cwdMustBeAbsolute) }
        return path
    }

    private static func environment(_ value: ActionValue) throws -> [String: String] {
        let text = try text(value)
        guard !text.isEmpty else { return [:] }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.values.allSatisfy({ $0 is String }) else {
            throw ActionFailure.invalidTarget(RoomStrings.envMustBeObject)
        }
        return object.compactMapValues { $0 as? String }
    }
}
