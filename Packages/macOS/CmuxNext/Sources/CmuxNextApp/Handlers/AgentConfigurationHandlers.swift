import CmuxNextActions
import CmuxNextAgentPane
import Foundation

/// The command-palette/CLI/MCP setters for a live agent chat's model, effort
/// and mode. The page bridge owns the session route and keeps the focused chat
/// projection in sync; this handler only resolves the target and waits for the
/// typed page action to settle.
enum AgentConfigurationHandlers {
    @MainActor
    private final class SuggestionStore {
        var models: [ActionEnumCase] = []
        let efforts = ["default", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
            .map { ActionEnumCase(value: $0, title: $0) }
        let modes = ["default", "read-only", "agent", "agent-full-access", "plan"]
            .map { ActionEnumCase(value: $0, title: $0) }
    }

    private struct Binding {
        let id: ActionID
        let argument: String
        let operation: AgentPaneConfigurationOperation
    }

    private static let bindings = [
        Binding(id: "agentPane.setModel", argument: "model", operation: .model),
        Binding(id: "agentPane.setEffort", argument: "effort", operation: .effort),
        Binding(id: "agentPane.setMode", argument: "mode", operation: .mode),
    ]

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        installSuggestions(on: registry, context: context)
        for binding in bindings {
            registry.bind(binding.id, run: { invocation in
                guard let value = invocation[binding.argument]?.stringValue,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return context.refuse(MiscHandlerStrings.noAgentChat)
                }
                guard let view = chatView(context, invocation) else { return }
                let operation = binding.operation
                context.report {
                    do {
                        try await view.setConfiguration(operation, value: value)
                        return nil
                    } catch {
                        return ActionWorkFailure("\(operation.rawValue): \(error)")
                    }
                }
            })
        }
    }

    /// Supplies the palette's argument picker from the daemon's model catalog
    /// once, while keeping typed ids accepted for custom harnesses. Effort and
    /// mode values are the protocol's stable names; model rows come from the
    /// live `_acpmux/models` response.
    private static func installSuggestions(on registry: ActionRegistry, context: AppActionContext) {
        let store = SuggestionStore()
        let previous = registry.argumentSuggestions
        registry.argumentSuggestions = { source in
            switch source {
            case ActionSuggestions.agentModels: store.models
            case ActionSuggestions.agentEfforts: store.efforts
            case ActionSuggestions.agentModes: store.modes
            default: previous?(source) ?? []
            }
        }
        let center = context.services.agentHarnesses
        Task { @MainActor in
            guard let answer = try? await center.models(), let harnesses = answer["harnesses"]?.arrayValue else { return }
            var choices: [String: ActionEnumCase] = [:]
            for harness in harnesses {
                guard let models = harness["models"]?.arrayValue else { continue }
                for model in models {
                    if let id = model.stringValue, !id.isEmpty {
                        choices[id] = ActionEnumCase(value: id, title: id)
                    } else if let id = model["id"]?.stringValue, !id.isEmpty {
                        choices[id] = ActionEnumCase(value: id, title: model["name"]?.stringValue ?? id)
                    }
                }
            }
            store.models = choices.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    /// A Priority row carries an `agent-chat:` session id rather than the tab
    /// id that `ActionScope` normally resolves. Explicit tab targets and the
    /// focused pane continue through the normal scope path.
    private static func chatView(_ context: AppActionContext, _ invocation: ActionInvocation) -> AgentPaneView? {
        if let target = invocation.target, target.kind == .agentChat {
            guard let key = context.services.agentTabs.tab(showing: target.id),
                  let view = context.services.agentTabs.existingView(key) else {
                context.refuse(MiscHandlerStrings.noAgentChat)
                return nil
            }
            return view
        }
        guard let pane = context.scope(invocation).pane,
              let key = context.scope(invocation).tab?.id.rawValue ?? pane.currentTabKey,
              let view = context.services.agentTabs.existingView(key) else {
            context.refuse(MiscHandlerStrings.noAgentChat)
            return nil
        }
        return view
    }
}
