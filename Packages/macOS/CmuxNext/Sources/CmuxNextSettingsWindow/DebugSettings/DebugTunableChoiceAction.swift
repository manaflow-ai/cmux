public import CmuxNextActions
public import CmuxNextDesign
import Foundation

/// One Debug Settings choice as a palette action with a list of its values (the old Debug menu's
/// Sidebar Toggle Icon and Status Icons submenus): the argument `argument` lists every value of `Choice`
/// (`ActionRegistry.argumentSuggestions`, source `suggestions`), and a run sets the choice the way its
/// Debug Settings row does: the default value removes the override. The change is the store's, made in
/// the run's turn; whatever reads the tunable follows the store's Observation. The action is
/// `isDebugOnly` in the catalog (DEV and NIGHTLY, Internal Developer Mode).
@MainActor public struct DebugTunableChoiceAction<Choice: TunableChoice & Equatable> {
    public let id: ActionID
    public let argument: String
    public let suggestions: String
    public let tunable: Tunable<Choice>
    public let store: TunableStore

    public init(id: ActionID, argument: String, suggestions: String, tunable: Tunable<Choice>, store: TunableStore = .shared) {
        self.id = id
        self.argument = argument
        self.suggestions = suggestions
        self.tunable = tunable
        self.store = store
    }

    /// Every value, titled as its Debug Settings row titles it.
    public var choices: [ActionEnumCase] {
        Choice.allCases.map { ActionEnumCase(value: $0.rawValue, title: $0.tunableTitle) }
    }

    /// Sets the choice (a run that changes nothing writes nothing).
    public func select(_ choice: Choice) {
        guard tunable.value(in: store) != choice else { return }
        if choice == tunable.defaultValue { store.reset([tunable.key]) } else { store.set(tunable.key, choice.tunableValue) }
    }

    public func bind(into registry: ActionRegistry) {
        let choices = choices
        registry.bindEffect(id) { invocation in
            guard let raw = invocation[argument]?.stringValue, let choice = Choice(rawValue: raw) else {
                let known = choices.map(\.value).joined(separator: ", ")
                return .refused(String(format: String(localized: "debug.tunableChoice.unknown", defaultValue: "Choose one of: %@",
                                                      bundle: .module), known))
            }
            select(choice)
            return .done
        }
        let others = registry.argumentSuggestions
        registry.argumentSuggestions = { source in source == suggestions ? choices : others?(source) ?? [] }
    }
}
