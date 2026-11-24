public import CmuxHomeCore
public import CmuxNextActions
public import CmuxNextDaemon
import Foundation

/// The palette form of `cmux chief edit|engine|adopt` (HomeActionCatalog): this Mac's Chief registry
/// through the app's trusted connection to its Chief owner, the same owner operations the CLI calls
/// (`chief.engine.set`, `chief.profile.adopt`). Edit Chief… opens the Chief's editor page, whose saves
/// are `chief.profile.update`. Their picks list the Chiefs and agents of this Mac's Home conversations
/// (``HomeChiefPicks``). The App binds them once.
@MainActor
public struct HomeChiefRegistryActions {
    private let connection: @MainActor () -> DaemonConnection?
    private let conversations: @MainActor () -> [CmuxHomeCore.ConversationSummary]
    private let deleted: @MainActor () -> Set<String>
    private let openEditor: @MainActor (String) -> String?

    /// - Parameters:
    ///   - connection: The app's trusted connection to this Mac's Chief owner; nil while it is not connected.
    ///   - conversations: The Home list's conversations of this Mac (no cloud one).
    ///   - deleted: This Mac's deleted Chiefs, which the list still names until it reads again.
    ///   - openEditor: Opens Chief `id`'s editor page (Home's `#/chief/<id>/edit`); the refusal when it cannot.
    public init(connection: @escaping @MainActor () -> DaemonConnection?, conversations: @escaping @MainActor () -> [CmuxHomeCore.ConversationSummary],
                deleted: @escaping @MainActor () -> Set<String>, openEditor: @escaping @MainActor (String) -> String?) {
        self.connection = connection
        self.conversations = conversations
        self.deleted = deleted
        self.openEditor = openEditor
    }

    /// Binds `home.editChief`, `home.setChiefModel`, `home.setChiefEffort` and `home.adoptChief`, and
    /// answers the ``ActionSuggestions/localChiefs`` and ``ActionSuggestions/adoptableAgents`` picks.
    public func bind(into registry: ActionRegistry) {
        let suggestions = registry.argumentSuggestions
        registry.argumentSuggestions = { [conversations, deleted] source in
            switch source {
            case ActionSuggestions.localChiefs: HomeChiefPicks(conversations()).localChiefs(deleted: deleted())
            case ActionSuggestions.adoptableAgents: HomeChiefPicks(conversations()).adoptableAgents()
            default: suggestions?(source) ?? []
            }
        }
        registry.bindEffect("home.editChief", effect: { [openEditor] invocation in
            guard let chief = Self.id(invocation["chief"]?.stringValue) else { return .refused(HomeChiefRegistryStrings.needsChief) }
            return openEditor(chief).map { .refused($0) } ?? .done
        })
        registry.bindEffect("home.setChiefModel", effect: { invocation in
            let model = invocation["model"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !model.isEmpty else { return .refused(HomeChiefRegistryStrings.needsModel) }
            return setEngine(["model": model], invocation)
        })
        registry.bindEffect("home.setChiefEffort", effect: { invocation in
            guard let effort = invocation["effort"]?.stringValue, !effort.isEmpty else { return .refused(HomeChiefRegistryStrings.needsEffort) }
            return setEngine(["effort": effort], invocation)
        })
        registry.bindEffect("home.adoptChief", effect: { [connection] invocation in
            guard let agent = Self.id(invocation["agent"]?.stringValue), agent.hasPrefix("agent_") else {
                return .refused(HomeChiefRegistryStrings.needsAgent)
            }
            guard let connection = connection() else { return .refused(HomeChiefEngineError.localUnreachable.text) }
            // action-wait-allow: the owner's registry decides (the agent may be gone or a Chief already); no local record stands in first
            return .waiting(.externalProcess) {
                do {
                    _ = try await ResourceRelayClient(connection: connection).send(
                        operation: "chief.profile.adopt",
                        params: ["participant_id": .string(agent), "machine": .string("current"), "session": .string("current")],
                        idempotencyKey: "home-chief-adopt-\(agent)-\(UUID().uuidString.lowercased())")
                    return nil
                } catch DaemonError.command(_, let message, let code, _, _) {
                    // The owner's refusal (an agent that is gone or a Chief already, a caller it does not take).
                    return ActionWorkFailure(refusal: .unavailable, reason: message.isEmpty ? (code ?? "chief.profile.adopt") : message)
                } catch {
                    return ActionWorkFailure(refusal: .unavailable, reason: HomeChiefEngineError.localUnreachable.text)
                }
            }
        })
    }

    /// One `chief.engine.set` of `fields` for the invocation's Chief, as `cmux chief engine --chief`.
    private func setEngine(_ fields: [String: String], _ invocation: ActionInvocation) -> ActionEffect {
        guard let chief = Self.id(invocation["chief"]?.stringValue) else { return .refused(HomeChiefRegistryStrings.needsChief) }
        guard let connection = connection() else { return .refused(HomeChiefEngineError.localUnreachable.text) }
        // action-wait-allow: the Chief's brain checks the value and may refuse it; the engine shows only once it took it
        return .waiting(.externalProcess) {
            do {
                _ = try await ChiefControlClient(connection).setChiefEngine(fields, chief: chief)
                return nil
            } catch let error as ChiefControlError {
                return ActionWorkFailure(refusal: .unavailable, reason: HomeChiefEngineError(error).text)
            } catch {
                return ActionWorkFailure(refusal: .unavailable, reason: HomeChiefEngineError.other(String(describing: error)).text)
            }
        }
    }

    /// A Chief or agent id as the owner and Home's routes take it (`[A-Za-z0-9_-]+`); nil otherwise.
    nonisolated static func id(_ text: String?) -> String? {
        guard let id = text?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty, id.count <= 128,
              id.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-") }) else {
            return nil
        }
        return id
    }

    /// Edit Chief… where the docked Home has no Channels view to open the editor in.
    public nonisolated static var editNeedsChannels: String { HomeChiefRegistryStrings.editNeedsChannels }
}

/// The Chief registry actions' refusals (table Home).
nonisolated enum HomeChiefRegistryStrings {
    static var needsChief: String { t("home.chiefRegistry.needsChief", "Pick one of this Mac's Chiefs.") }
    static var needsAgent: String { t("home.chiefRegistry.needsAgent", "Pick an agent from your conversations (an agent_… id).") }
    static var needsModel: String { t("home.chiefRegistry.needsModel", "Type the model the Chief should use.") }
    static var needsEffort: String { t("home.chiefRegistry.needsEffort", "Pick the effort the Chief should use.") }
    /// Edit Chief… where the docked Home has no Channels view to open the editor in.
    static var editNeedsChannels: String {
        t("home.chiefRegistry.editNeedsChannels", "Edit Chief… opens in Home's Channels view, which is off.")
    }

    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "Home", bundle: .module)
    }
}
