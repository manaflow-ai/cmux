/// The pickable objects of a target-kind argument in a choices submenu
/// (Set Browser Profile > Personal, Work) and the checked one, supplied by
/// the App through ``ActionRegistry/targetChoices`` from the same lists the
/// palette shows. Nil or no cases leaves the row out of the menu.
public nonisolated struct ActionTargetChoices: Sendable, Hashable {
    public var cases: [ActionEnumCase]
    public var current: String?

    public init(cases: [ActionEnumCase], current: String? = nil) {
        self.cases = cases
        self.current = current
    }

    /// The kind of a target argument a choices submenu can list: one the
    /// action does not act on itself (Set Space Browser Profile acts on a
    /// space and picks a browser profile).
    static func kind(of argument: ActionArgument, in descriptor: ActionDescriptor) -> ActionTargetKind? {
        guard case .target(let kind) = argument.kind, !descriptor.targets.contains(kind) else { return nil }
        return kind
    }

    /// The argument a choices submenu picks, its values and the checked one:
    /// an enumeration or suggested string first, else a listed target kind.
    @MainActor
    static func resolve(_ descriptor: ActionDescriptor, target: ActionTargetRef?,
                        in registry: ActionRegistry) -> (ActionArgument, [ActionEnumCase], String?)? {
        if let (argument, cases) = descriptor.arguments.lazy.compactMap(ActionRegistry.menuChoices).first {
            return (argument, cases, registry.choiceState?(descriptor.id, target))
        }
        guard let argument = descriptor.arguments.first(where: { kind(of: $0, in: descriptor) != nil }),
              let kind = kind(of: argument, in: descriptor),
              let listed = registry.targetChoices?(descriptor.id, kind, target) else { return nil }
        return (argument, listed.cases, listed.current)
    }
}
