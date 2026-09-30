import CmuxNextActions
import Foundation

/// Collects an action's required arguments inline, one page per argument,
/// straight from its schema: text entry for strings and numbers, a list for
/// booleans, enumerations, and targets. The last step runs the action with
/// the full invocation.
struct PaletteArgumentFlow {
    let registry: ActionRegistry
    let descriptor: ActionDescriptor
    let targets: (any PaletteTargetSource)?
    /// Captured when the palette opened (`PaletteSources.context`).
    var captured: [ActionTargetRef] = []

    func effect(collected: ActionInvocation) -> PaletteEffect {
        let registry = registry
        let id = descriptor.id
        guard let argument = descriptor.arguments.first(where: { $0.isRequired && collected.arguments[$0.name] == nil }) else {
            return .perform { registry.perform(id, invocation: collected) }
        }
        // An input step follows, and the action runs after the palette
        // closes: pin its target to what was focused when it opened.
        var collected = collected
        if collected.target == nil, let target = capturedTarget {
            collected.target = target
        }
        switch argument.kind {
        case .string, .int:
            return .textInput(textSpec(for: argument, collected: collected))
        case .bool:
            return .push(listPage(for: argument, options: [
                PaletteTargetOption(id: "true", title: PaletteStrings.on, symbol: "checkmark.circle"),
                PaletteTargetOption(id: "false", title: PaletteStrings.off, symbol: "circle"),
            ], collected: collected))
        case .enumeration(let cases):
            let options = cases.map { PaletteTargetOption(id: $0.value, title: $0.title, symbol: descriptor.symbol) }
            return .push(listPage(for: argument, options: options, collected: collected))
        case .target(let kind):
            guard let targets else { return .textInput(textSpec(for: argument, collected: collected)) }
            return .push(listPage(for: argument, options: targets.targets(of: kind), collected: collected))
        }
    }

    /// The captured object of the first kind the action targets.
    var capturedTarget: ActionTargetRef? {
        for kind in descriptor.targets {
            if let ref = captured.first(where: { $0.kind == kind }) { return ref }
        }
        return nil
    }

    private func adding(_ argument: ActionArgument, _ text: String, to collected: ActionInvocation) -> ActionInvocation? {
        guard let value = argument.parse(text) else { return nil }
        var next = collected
        next.arguments[argument.name] = value
        return next
    }

    private func textSpec(for argument: ActionArgument, collected: ActionInvocation) -> PaletteTextInputSpec {
        let flow = self
        return PaletteTextInputSpec(
            id: "argument:\(descriptor.id.rawValue):\(argument.name)",
            title: Self.stepTitle(descriptor, argument),
            placeholder: argument.title,
            symbol: descriptor.symbol,
            submitTitle: { text in PaletteStrings.submitText(title: descriptor.title, text: text) },
            isValid: { text in
                !text.trimmingCharacters(in: .whitespaces).isEmpty && argument.parse(text) != nil
            },
            next: { text in
                guard let next = flow.adding(argument, text, to: collected) else { return .performKeepingOpen {} }
                return flow.effect(collected: next)
            }
        )
    }

    private func listPage(for argument: ActionArgument, options: [PaletteTargetOption], collected: ActionInvocation) -> PalettePageSpec {
        let section = PaletteSection(id: "argument", title: argument.title, order: 0)
        let items = options.map { option in
            let next = adding(argument, option.id, to: collected)
            return PaletteItem(
                id: "option:\(option.id)",
                title: option.title,
                subtitle: option.subtitle,
                symbol: option.symbol ?? descriptor.symbol,
                section: section,
                isEnabled: next != nil,
                primary: PaletteCommand(
                    id: "choose",
                    title: PaletteStrings.choose,
                    symbol: "return",
                    effect: next.map { effect(collected: $0) } ?? .performKeepingOpen {}
                ),
                frecencyKey: "argument:\(descriptor.id.rawValue):\(argument.name):\(option.id)"
            )
        }
        return PalettePageSpec(
            id: "argument:\(descriptor.id.rawValue):\(argument.name)",
            title: Self.stepTitle(descriptor, argument),
            placeholder: PaletteStrings.chooseArgument(argument.title),
            symbol: descriptor.symbol,
            providers: [StaticPaletteProvider(id: "argument", items: items)],
            showsRecent: true
        )
    }

    /// "Set Tab Group Color: Color" reads badly; use the action title for
    /// single-argument actions and "Title › Argument" otherwise.
    static func stepTitle(_ descriptor: ActionDescriptor, _ argument: ActionArgument) -> String {
        let base = descriptor.title.hasSuffix("…") ? String(descriptor.title.dropLast()) : descriptor.title
        let required = descriptor.arguments.filter(\.isRequired)
        return required.count <= 1 ? base : "\(base) › \(argument.title)"
    }
}
