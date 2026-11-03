import CmuxNextActions
import Foundation

/// A multi-value argument (``ActionSuggestions/allowsMultiple``, New Group Chat's members): every
/// known value is a row; Return on one adds it as a chip (or takes it out again) and keeps the
/// list open, the query clears for the next name, typed text that matches nobody is offered as
/// its own row (an email address), and Continue sends the chosen values comma-joined.
extension PaletteArgumentFlow {
    /// The id of the row that ends a multi-value step.
    static let continueRowID = "continue"

    func multipleChoicePage(for argument: ActionArgument, chosen: [ActionEnumCase], collected: ActionInvocation) -> PalettePageSpec {
        let source = argument.suggestions?.source ?? ""
        let known = registry.argumentSuggestions?(source) ?? []
        let chosenValues = Set(chosen.map(\.value))
        let section = PaletteSection(id: "argument", title: argument.title, order: 1)
        let flow = self
        let toggled = { (value: ActionEnumCase) -> PalettePageSpec in
            let next = chosenValues.contains(value.value) ? chosen.filter { $0.value != value.value } : chosen + [value]
            var page = flow.multipleChoicePage(for: argument, chosen: next, collected: collected)
            page.emptyQuerySelectionID = "option:\(value.value)"
            return page
        }
        // Chosen typed values (an address) stay listed so they can be taken out like the rest.
        let typed = chosen.filter { value in !known.contains { $0.value == value.value } }
        var items: [PaletteItem] = (known + typed).map { value in
            var item = PaletteItem(
                id: "option:\(value.value)", title: value.title, symbol: "person.crop.circle", section: section,
                primary: PaletteCommand(id: "choose", title: PaletteStrings.choose, symbol: "return",
                                        effect: .deferred { .replace(toggled(value)) }),
                frecencyKey: "argument:\(descriptor.id.rawValue):\(argument.name):\(value.value)"
            )
            if chosenValues.contains(value.value) { item.accessory = PaletteStrings.added }
            return item
        }
        if !chosen.isEmpty {
            let names = chosen.map(\.title).joined(separator: ", ")
            let value = chosen.map(\.value).joined(separator: ",")
            let next = adding(argument, value, to: collected)
            items.insert(PaletteItem(
                id: Self.continueRowID, title: PaletteStrings.continueWith(names), symbol: "arrow.right.circle",
                section: PaletteSection(id: "continue", title: Self.baseTitle(descriptor.title), order: 0),
                isEnabled: next != nil,
                primary: PaletteCommand(id: "choose", title: PaletteStrings.choose, symbol: "return",
                                        effect: next.map { effect(collected: $0) } ?? .performKeepingOpen {})
            ), at: 0)
        }
        var page = PalettePageSpec(
            id: "argument:\(descriptor.id.rawValue):\(argument.name)",
            title: Self.stepTitle(descriptor, argument),
            placeholder: PaletteStrings.chooseArgument(argument.title),
            symbol: descriptor.symbol,
            providers: [StaticPaletteProvider(id: "argument", items: items)],
            keepsSectionOrder: true,
            queryItems: { text in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !chosenValues.contains(trimmed),
                      !known.contains(where: { $0.title.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return [] }
                let value = ActionEnumCase(value: trimmed, title: trimmed)
                return [PaletteItem(
                    id: "typed", title: PaletteStrings.addTyped(trimmed), symbol: "plus.circle", section: section,
                    primary: PaletteCommand(id: "choose", title: PaletteStrings.choose, symbol: "return",
                                            effect: .deferred { .replace(toggled(value)) })
                )]
            }
        )
        page.tokens = chosen.map { value in
            PaletteToken(id: value.value, title: value.title, remove: { toggled(value) })
        }
        return page
    }
}
