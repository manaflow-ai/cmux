import CmuxNextActions
import Foundation

extension PaletteArgumentFlow {
    /// The row a target page shows when the typed name matches none of its targets: make one by
    /// that name, then run the action on it (New Tab with Browser Profile… typed "austin": Create
    /// Browser Profile “austin”, then the tab opens in it). Nil when nothing can make the kind, or
    /// when another step would follow (the palette closes before the new target exists).
    func creationRows(for argument: ActionArgument, kind: ActionTargetKind,
                      collected: ActionInvocation) -> (@MainActor (String) -> [PaletteItem])? {
        guard let creator = creators[kind] else { return nil }
        let laterSteps = descriptor.arguments.contains { other in
            other.name != argument.name && (other.isRequired || other.name == ask?.argument) && collected.arguments[other.name] == nil
        }
        guard !laterSteps else { return nil }
        let flow = self
        return { query in
            let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return [] }
            let section = PaletteSection(id: "argument.create", title: argument.title, order: -1)
            let effect = PaletteEffect.perform { flow.create(name, with: creator, for: argument, collected: collected) }
            return [PaletteItem(
                id: "create:\(kind.rawValue)", title: creator.title(name), symbol: creator.symbol, section: section,
                primary: PaletteCommand(id: "create", title: PaletteStrings.create, symbol: "return", effect: effect),
                frecencyKey: nil
            )]
        }
    }

    /// Makes the target, then runs the action with it. The work goes to the registry like any action's
    /// (``ActionRegistry/trackOrRefuse(_:)``): a capturing caller awaits it, and a palette run nobody awaits
    /// shows a failure to make the target as the action's refusal.
    private func create(_ name: String, with creator: PaletteTargetCreator, for argument: ActionArgument,
                        collected: ActionInvocation) {
        let registry = registry
        let id = descriptor.id
        let flow = self
        // task-owner: one create-then-run after the palette closed; it ends with the action's run.
        registry.trackOrRefuse(Task { () async -> ActionWorkFailure? in
            do {
                let created = try await creator.create(name)
                guard let next = flow.adding(argument, created, to: collected) else { return nil }
                registry.perform(id, invocation: next)
                return nil
            } catch is CancellationError {
                return nil
            } catch {
                return ActionWorkFailure(refusal: .unavailable, reason: (error as? LocalizedError)?.errorDescription
                    ?? (error as? CustomStringConvertible)?.description ?? error.localizedDescription)
            }
        })
    }
}
