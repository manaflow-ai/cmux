import CmuxNextActions
import CmuxNextDaemon
import Foundation

/// Target resolution for room handlers. Rooms live on the local daemon.
extension AppActionContext {
    var roomStore: DaemonStore { services.machines.local.store }

    func requireRooms() throws {
        guard services.machines.local.supports(DaemonCapabilities.shared.profiles) else {
            throw ActionFailure(message: services.machines.local.missingCapabilityMessage(DaemonCapabilities.shared.profiles))
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

/// `space.setDefaults` arguments: `cwd` (a directory, `~` expanded) and
/// `env` (a JSON object of strings). Both empty clears the defaults.
enum RoomDefaultsArguments {
    static func parse(_ invocation: ActionInvocation) throws -> ProfileDefaults {
        var defaults = ProfileDefaults()
        if let cwd = invocation["cwd"]?.stringValue?.trimmingCharacters(in: .whitespaces), !cwd.isEmpty {
            defaults.cwd = (cwd as NSString).expandingTildeInPath
        }
        if let text = invocation["env"]?.stringValue?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object.values.allSatisfy({ $0 is String }) else {
                throw ActionFailure.invalidTarget(RoomStrings.envMustBeObject)
            }
            defaults.env = object.compactMapValues { $0 as? String }
        }
        return defaults
    }
}
