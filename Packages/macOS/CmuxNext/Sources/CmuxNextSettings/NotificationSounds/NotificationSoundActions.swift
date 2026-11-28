import AppKit
public import CmuxNextActions
import Foundation

/// The notification sound actions: a sound (or no sound, or inherit) and a volume for a workspace,
/// a group, an agent kind or one event; a preview; an import. Every surface (the workspace row and
/// group menus' Notification Sound submenu, the palette, the CLI `cmux notification set-…-sound`,
/// MCP) runs these. Each change shows at once (the live preferences) and is written to cmux.json
/// through the validated settings path; a refused write rolls the live value back.
@MainActor
public final class NotificationSoundActions {
    private let host: any NotificationSoundHost
    private let gate: NotificationSoundGate
    private let importer: NotificationSoundImport

    /// A target the invocation does not name (its message is the person's).
    private struct Refusal: Error {
        let message: String
    }

    /// - Parameters:
    ///   - host: The App's side (preferences, settings write, targets, groups).
    ///   - gate: The notification service's sound gate: previews play through its player, it
    ///     learns the person's groups from `host`, and its library lists and imports sounds.
    public init(host: any NotificationSoundHost, gate: NotificationSoundGate) {
        self.host = host
        self.gate = gate
        importer = NotificationSoundImport(host: host, gate: gate)
    }

    /// Binds the actions, the palette's sound and agent lists, and the menus' checked sound.
    public func bind(into registry: ActionRegistry) {
        gate.groups = { [weak host] in host?.soundGroups(ofWorkspace: $0) ?? [] }
        Task { [gate, host] in await gate.refreshSounds(work: host.soundWork) }
        registry.bindEffect("notifications.setWorkspaceSound", effect: { [self, weak registry] invocation in
            level(registry, "notifications.setWorkspaceSound", invocation) { try Self.level("workspace", self.host.soundWorkspace($0)) }
        })
        registry.bindEffect("notifications.setGroupSound", effect: { [self, weak registry] invocation in
            level(registry, "notifications.setGroupSound", invocation) { try Self.level("group", self.host.soundGroup($0).id) }
        })
        registry.bindEffect("notifications.setAgentSound", effect: { [self, weak registry] invocation in
            level(registry, "notifications.setAgentSound", invocation) { invocation in
                guard let agent = invocation["agent"]?.stringValue?.trimmingCharacters(in: .whitespaces).lowercased(), !agent.isEmpty else {
                    throw Refusal(message: NotificationSoundStrings.noAgent)
                }
                return Self.level("agent", agent)
            }
        })
        registry.bindEffect("notifications.setEventSound", effect: { [self, weak registry] invocation in
            level(registry, "notifications.setEventSound", invocation) { invocation in
                guard let event = invocation["event"]?.stringValue.flatMap(NotificationSoundEvent.init(rawValue:)) else {
                    throw Refusal(message: NotificationSoundStrings.noEvent)
                }
                return Self.level("event", event.rawValue)
            }
        })
        registry.bindEffect("notifications.previewSound", effect: { [self] invocation in preview(invocation) })
        registry.bindEffect("notifications.importSound", effect: { [self] invocation in
            let file = Self.file(invocation)
            // action-wait-allow: the person picks a file in the open panel (or the CLI names one), and the copy reads the disk; nothing changes before it lands
            return .waiting(.fileSystem) { [self] in
                if case .failure(let failure) = await importer.run(file) { return failure }
                return nil
            }
        })
        bindLists(into: registry)
    }

    // MARK: Set

    /// One change at the level `target` names (its refusal is the person's message).
    private func level(_ registry: ActionRegistry?, _ id: ActionID, _ invocation: ActionInvocation,
                       _ target: (ActionInvocation) throws -> JSONValue) -> ActionEffect {
        let level: JSONValue
        do { level = try target(invocation) } catch let refusal as Refusal {
            return .refused(refusal.message)
        } catch {
            return .refused(host.soundRefusal(error))
        }
        let sound = invocation["sound"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let event = invocation["event"]?.stringValue.flatMap(NotificationSoundEvent.init(rawValue:))
        let volume = invocation["volume"]?.intValue.map { Double($0) / 100 }
        let file = Self.file(invocation)
        guard sound != nil || volume != nil || file != nil else {
            // The palette asks for the sound; Return runs this again with it.
            guard let registry, !registry.refusalHasCaller, registry.ask(id, invocation, ActionArgumentAsk(argument: "sound")) else {
                return .refused(NotificationSoundStrings.needsSound)
            }
            return .done
        }
        let writer = SettingWriter.currentRun()
        let previews = invocation.origin == .user
        guard sound == "choose" || file != nil else {
            let change = apply(level, sound: sound, event: event, volume: volume)
            if previews, let sound, !["inherit", "none"].contains(sound) { gate.preview(sound, volume: (volume ?? 1) * host.soundPreferences.sounds.volume) }
            return .applied(ActionConfirmation(send: { [host] in await host.writeSoundSetting(change.path, change.value, by: writer) },
                                               rollback: { [host] _ in host.applySoundPreferences(change.before) }))
        }
        // action-wait-allow: the person picks a file in the open panel (or the CLI names one), and the copy reads the disk; nothing changes before it lands
        return .waiting(.fileSystem) { [self] in
            switch await importer.run(file) {
            case .failure(let failure): return failure
            case .success(nil): return nil
            case .success(let name?):
                let change = apply(level, sound: name, event: event, volume: volume)
                if previews { gate.preview(name, volume: (volume ?? 1) * host.soundPreferences.sounds.volume) }
                guard let failure = await host.writeSoundSetting(change.path, change.value, by: writer) else { return nil }
                host.applySoundPreferences(change.before)
                return failure
            }
        }
    }

    /// Where one change lands (`notifications.sound_edit`'s level).
    private static func level(_ kind: String, _ key: String) -> JSONValue { ["kind": .string(kind), "key": .string(key)] }

    /// Applies one change to the live preferences and returns what to write and what to restore.
    private func apply(_ level: JSONValue, sound: String?, event: NotificationSoundEvent?, volume: Double?)
        -> (before: NotificationSoundPreferences, path: [String], value: JSONValue?) {
        let before = host.soundPreferences.sounds
        let reply = SettingsRust.answer("notifications.sound_edit", [
            "sounds": SettingsRust.json(before), "level": level, "sound": sound.map(JSONValue.string) ?? .null,
            "event": event.map { .string($0.rawValue) } ?? .null, "volume": volume.map(JSONValue.number) ?? .null,
        ])
        host.applySoundPreferences(SettingsRust.decode(reply["sounds"]) ?? before)
        let path = (reply["path"]?.arrayValue ?? []).compactMap(\.stringValue)
        return (before, path, reply["value"].flatMap { $0 == .null ? nil : $0 })
    }

    // MARK: Preview

    /// Plays what the targeted workspace's `event` (default: an agent finishing) would play now.
    private func preview(_ invocation: ActionInvocation) -> ActionEffect {
        let workspace: String
        do { workspace = try host.soundWorkspace(invocation) } catch { return .refused(host.soundRefusal(error)) }
        let event = invocation["event"]?.stringValue.flatMap(NotificationSoundEvent.init(rawValue:)) ?? .finished
        let scope = NotificationSoundScope(workspace: workspace, groups: host.soundGroups(ofWorkspace: workspace))
        let reply = SettingsRust.answer("notifications.preview_choice", [
            "prefs": SettingsRust.json(host.soundPreferences), "scope": SettingsRust.json(scope), "event": .string(event.rawValue),
        ])
        guard let choice = SettingsRust.decode(reply["choice"], as: NotificationSoundChoice.self) else {
            return .refused(NotificationSoundStrings.silent)
        }
        gate.preview(choice.name, volume: choice.volume)
        return .done
    }

    // MARK: Import

    /// The invocation's `file` (CLI), expanded; nil when absent.
    private static func file(_ invocation: ActionInvocation) -> URL? {
        guard let path = invocation["file"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    // MARK: Lists

    /// The palette's full sound and agent lists, and the checked sound in a level's submenu.
    private func bindLists(into registry: ActionRegistry) {
        let otherSuggestions = registry.argumentSuggestions
        registry.argumentSuggestions = { [weak self] source in
            guard let self else { return otherSuggestions?(source) ?? [] }
            switch source {
            case ActionSuggestions.notificationSounds:
                return gate.soundNames.map { ActionEnumCase(value: $0, title: $0) }
            case ActionSuggestions.notificationAgents:
                let kinds = Set(host.soundAgentKinds.compactMap(NotificationSoundGate.agentKind))
                return kinds.sorted().map { ActionEnumCase(value: $0, title: $0) }
            default:
                return otherSuggestions?(source) ?? []
            }
        }
        let otherState = registry.choiceState
        registry.choiceState = { [weak self] action, target in
            guard let self else { return otherState?(action, target) }
            let sounds = host.soundPreferences.sounds
            switch action {
            case "notifications.setWorkspaceSound":
                return (try? host.soundWorkspace(ActionInvocation(target: target))).map { sounds.workspaces[$0]?.sound ?? "inherit" }
            case "notifications.setGroupSound":
                return (try? host.soundGroup(ActionInvocation(target: target))).map { sounds.groups[$0.id]?.sound ?? sounds.groups[$0.name]?.sound ?? "inherit" }
            default:
                return otherState?(action, target)
            }
        }
    }
}
