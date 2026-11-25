import AppKit
public import CmuxNextActions
import Foundation
import UniformTypeIdentifiers

/// The notification sound actions: a sound (or no sound, or inherit) and a volume for a workspace,
/// a group, an agent kind or one event; a preview; an import. Every surface (the workspace row and
/// group menus' Notification Sound submenu, the palette, the CLI `cmux notification set-…-sound`,
/// MCP) runs these. Each change shows at once (the live preferences) and is written to cmux.json
/// through the validated settings path; a refused write rolls the live value back.
@MainActor
public final class NotificationSoundActions {
    private let host: any NotificationSoundHost
    private let gate: NotificationSoundGate
    private let library: NotificationSoundLibrary
    /// Installed sound names, listed off the main thread at bind and after each import.
    private var names: [String] = []

    /// A target the invocation does not name (its message is the person's).
    private struct Refusal: Error {
        let message: String
    }

    /// Where one change lands.
    private enum Level {
        case workspace(String)
        case group(String)
        case agent(String)
        case event(NotificationSoundEvent)
    }

    /// - Parameters:
    ///   - host: The App's side (preferences, settings write, targets, groups).
    ///   - gate: The notification service's sound gate: previews play through its player, and it
    ///     learns the person's groups from `host`.
    ///   - library: Where sounds are listed and imported.
    public init(host: any NotificationSoundHost, gate: NotificationSoundGate, library: NotificationSoundLibrary = NotificationSoundLibrary()) {
        self.host = host
        self.gate = gate
        self.library = library
    }

    /// Binds the actions, the palette's sound and agent lists, and the menus' checked sound.
    public func bind(into registry: ActionRegistry) {
        gate.groups = { [weak host] in host?.soundGroups(ofWorkspace: $0) ?? [] }
        refreshNames()
        registry.bindEffect("notifications.setWorkspaceSound", effect: { [self, weak registry] invocation in
            level(registry, "notifications.setWorkspaceSound", invocation) { try .workspace(self.host.soundWorkspace($0)) }
        })
        registry.bindEffect("notifications.setGroupSound", effect: { [self, weak registry] invocation in
            level(registry, "notifications.setGroupSound", invocation) { try .group(self.host.soundGroup($0).id) }
        })
        registry.bindEffect("notifications.setAgentSound", effect: { [self, weak registry] invocation in
            level(registry, "notifications.setAgentSound", invocation) { invocation in
                guard let agent = invocation["agent"]?.stringValue?.trimmingCharacters(in: .whitespaces).lowercased(), !agent.isEmpty else {
                    throw Refusal(message: NotificationSoundStrings.noAgent)
                }
                return .agent(agent)
            }
        })
        registry.bindEffect("notifications.setEventSound", effect: { [self, weak registry] invocation in
            level(registry, "notifications.setEventSound", invocation) { invocation in
                guard let event = invocation["event"]?.stringValue.flatMap(NotificationSoundEvent.init(rawValue:)) else {
                    throw Refusal(message: NotificationSoundStrings.noEvent)
                }
                return .event(event)
            }
        })
        registry.bindEffect("notifications.previewSound", effect: { [self] invocation in preview(invocation) })
        registry.bindEffect("notifications.importSound", effect: { [self] invocation in
            let file = Self.file(invocation)
            // action-wait-allow: the person picks a file in the open panel (or the CLI names one), and the copy reads the disk; nothing changes before it lands
            return .waiting(.fileSystem) { [self] in
                if case .failure(let failure) = await importSound(file) { return failure }
                return nil
            }
        })
        bindLists(into: registry)
    }

    // MARK: Set

    /// One change at the level `target` names (its refusal is the person's message).
    private func level(_ registry: ActionRegistry?, _ id: ActionID, _ invocation: ActionInvocation,
                       _ target: (ActionInvocation) throws -> Level) -> ActionEffect {
        let level: Level
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
            switch await importSound(file) {
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

    /// Applies one change to the live preferences and returns what to write and what to restore.
    private func apply(_ level: Level, sound: String?, event: NotificationSoundEvent?, volume: Double?)
        -> (before: NotificationSoundPreferences, path: [String], value: JSONValue?) {
        var sounds = host.soundPreferences.sounds
        let before = sounds
        let root = ["notifications", "sounds"]
        let result: (path: [String], value: JSONValue?)
        switch level {
        case .event(let event):
            if let sound { sounds.events[event] = sound == "inherit" ? nil : sound }
            result = (root + ["events", event.rawValue], sounds.events[event].map(JSONValue.string))
        case .workspace(let key):
            result = (root + ["workspaces"], Self.edit(&sounds.workspaces, key, sound: sound, event: event, volume: volume))
        case .group(let key):
            result = (root + ["groups"], Self.edit(&sounds.groups, key, sound: sound, event: event, volume: volume))
        case .agent(let key):
            result = (root + ["agents"], Self.edit(&sounds.agents, key, sound: sound, event: event, volume: volume))
        }
        host.applySoundPreferences(sounds)
        return (before, result.path, result.value)
    }

    /// Edits `key`'s rule in `map` and returns the map as cmux.json holds it (nil when empty).
    private static func edit(_ map: inout [String: NotificationSoundRule], _ key: String, sound: String?,
                             event: NotificationSoundEvent?, volume: Double?) -> JSONValue? {
        let rule = (map[key] ?? NotificationSoundRule()).applying(sound: sound, event: event, volume: volume)
        map[key] = rule.isEmpty ? nil : rule
        return map.isEmpty ? nil : .object(map.mapValues(\.json))
    }

    // MARK: Preview

    /// Plays what the targeted workspace's `event` (default: an agent finishing) would play now.
    private func preview(_ invocation: ActionInvocation) -> ActionEffect {
        let workspace: String
        do { workspace = try host.soundWorkspace(invocation) } catch { return .refused(host.soundRefusal(error)) }
        let event = invocation["event"]?.stringValue.flatMap(NotificationSoundEvent.init(rawValue:)) ?? .finished
        let prefs = host.soundPreferences
        let scope = NotificationSoundScope(workspace: workspace, groups: host.soundGroups(ofWorkspace: workspace))
        guard !prefs.mutedWorkspaces.contains(workspace),
              let choice = prefs.sounds.choice(for: event, in: scope, fallback: prefs.sound(for: Self.source(of: event))) else {
            return .refused(NotificationSoundStrings.silent)
        }
        gate.preview(choice.name, volume: choice.volume)
        return .done
    }

    /// The source whose `notifications.sound` an event falls back to.
    private static func source(of event: NotificationSoundEvent) -> NotificationSource {
        switch event {
        case .finished, .needsInput, .error: .agent
        case .bell: .terminal
        case .message: .cli
        }
    }

    // MARK: Import

    /// The invocation's `file` (CLI), expanded; nil when absent.
    private static func file(_ invocation: ActionInvocation) -> URL? {
        guard let path = invocation["file"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// Imports `file`, or the file the person picks (nil name: they cancelled).
    private func importSound(_ file: URL?) async -> Result<String?, ActionWorkFailure> {
        var picked = file
        if picked == nil { picked = await choose() }
        guard let url = picked else { return .success(nil) }
        let library = library
        do {
            let name = try await host.soundWork.run(.userBlocking, mayBlock: .files) { try library.importSound(from: url) }
            refreshNames()
            return .success(name)
        } catch let refusal as NotificationSoundLibrary.ImportRefusal {
            return .failure(ActionWorkFailure(refusal.message))
        } catch {
            return .failure(ActionWorkFailure(NotificationSoundStrings.importFailed(url.lastPathComponent)))
        }
    }

    /// The sound file the person picks, nil on cancel.
    private func choose() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        panel.message = NotificationSoundStrings.chooseMessage
        panel.prompt = NotificationSoundStrings.choosePrompt
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            if let anchor = host.soundAnchorWindow {
                panel.beginSheetModal(for: anchor) { continuation.resume(returning: $0) }
            } else {
                panel.begin { continuation.resume(returning: $0) }
            }
        }
        return response == .OK ? panel.url : nil
    }

    // MARK: Lists

    /// The palette's full sound and agent lists, and the checked sound in a level's submenu.
    private func bindLists(into registry: ActionRegistry) {
        let otherSuggestions = registry.argumentSuggestions
        registry.argumentSuggestions = { [weak self] source in
            guard let self else { return otherSuggestions?(source) ?? [] }
            switch source {
            case ActionSuggestions.notificationSounds:
                return names.map { ActionEnumCase(value: $0, title: $0) }
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

    /// Lists the installed sounds off the main thread.
    private func refreshNames() {
        let library = library, work = host.soundWork
        Task { [weak self] in
            let listed = (try? await work.run(.bestEffort, mayBlock: .files) { library.names() }) ?? []
            self?.names = listed
        }
    }
}
