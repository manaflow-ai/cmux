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
    /// Previews the highlighted option of an enumeration page.
    var preview: PaletteArgumentPreview?
    /// Colors for a suggested value's row (theme swatch strips, R98).
    var swatches: PaletteArgumentSwatches?
    /// An argument a handler asks for although the schema makes it optional (a menu Rename with
    /// no name, ``ActionRegistry/ask(_:_:_:)``): it is collected like a required one.
    var ask: ActionArgumentAsk?

    func effect(collected: ActionInvocation) -> PaletteEffect {
        let registry = registry
        let id = descriptor.id
        guard let argument = descriptor.arguments.first(where: { asks(for: $0) && collected.arguments[$0.name] == nil }) else {
            return .perform { registry.perform(id, invocation: collected) }
        }
        // An input step follows, and the action runs after the palette
        // closes: pin its target to what was focused when it opened.
        var collected = collected
        if collected.target == nil, let target = capturedTarget {
            collected.target = target
        }
        switch argument.kind {
        case .string where argument.suggestions?.allowsMultiple == true:
            return .push(multipleChoicePage(for: argument, chosen: [], collected: collected))
        case .string where argument.suggestions != nil:
            return .push(withPreview(suggestionPage(for: argument, collected: collected), argument, collected))
        case .string, .int:
            return .textInput(textSpec(for: argument, collected: collected))
        case .bool:
            return .push(listPage(for: argument, options: [
                PaletteTargetOption(id: "true", title: PaletteStrings.on, symbol: "checkmark.circle"),
                PaletteTargetOption(id: "false", title: PaletteStrings.off, symbol: "circle"),
            ], collected: collected))
        case .enumeration(let cases):
            let options = cases.map { PaletteTargetOption(id: $0.value, title: $0.title, symbol: descriptor.symbol) }
            return .push(withPreview(listPage(for: argument, options: options, collected: collected), argument, collected))
        case .target(let kind):
            guard let targets else { return .textInput(textSpec(for: argument, collected: collected)) }
            var page = listPage(for: argument, options: targets.targets(of: kind, for: descriptor.id), collected: collected)
            if let updates = targets.targetUpdates(of: kind, for: descriptor.id) {
                let flow = self
                let invocation = collected
                page.providers = [AsyncPaletteProvider.streaming(id: "argument", immediateItems: page.providers.first?.immediateItems) {
                    let (stream, continuation) = AsyncStream.makeStream(of: [PaletteItem].self, bufferingPolicy: .bufferingNewest(1))
                    // task-owner: maps one open's option lists to rows; ends with the stream's consumer
                    let task = Task { @MainActor in
                        for await options in updates() {
                            let loaded = flow.listPage(for: argument, options: options, collected: invocation)
                            continuation.yield(await loaded.providers.first?.items() ?? [])
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                    return stream
                }]
            } else if let refresh = targets.targetRefresh(of: kind, for: descriptor.id) {
                let flow = self
                let invocation = collected
                page.providers = [AsyncPaletteProvider(id: "argument", immediateItems: page.providers.first?.immediateItems) {
                    let options = await refresh()
                    guard !Task.isCancelled else { return [] }
                    let loaded = flow.listPage(for: argument, options: options, collected: invocation)
                    return await loaded.providers.first?.items() ?? []
                }]
            }
            return .push(page)
        }
    }

    private func asks(for argument: ActionArgument) -> Bool {
        argument.isRequired || argument.name == ask?.argument
    }

    /// Live preview of the highlighted option (theme pickers).
    private func withPreview(_ page: PalettePageSpec, _ argument: ActionArgument, _ collected: ActionInvocation) -> PalettePageSpec {
        guard let preview else { return page }
        var page = page
        let id = descriptor.id
        let name = argument.name
        let target = collected.target
        page.onHighlight = { item in preview(id, name, item.flatMap(Self.optionValue), target) }
        page.onLeave = { preview(id, name, nil, target) }
        return page
    }

    /// A free-text argument with known values: its pinned values, a row for
    /// other text (a light/dark pair), then every known value; typing
    /// searches them.
    private func suggestionPage(for argument: ActionArgument, collected: ActionInvocation) -> PalettePageSpec {
        guard let suggestions = argument.suggestions else { return listPage(for: argument, options: [], collected: collected) }
        let pinned = Set(suggestions.pinned.map(\.value))
        let known = (registry.argumentSuggestions?(suggestions.source) ?? []).filter { !pinned.contains($0.value) }
        let options = (suggestions.pinned + known).map { suggestion in
            PaletteTargetOption(id: suggestion.value, title: suggestion.title, symbol: descriptor.symbol,
                                swatches: swatches?(suggestions.source, suggestion.value) ?? [])
        }
        var extra: [PaletteItem] = []
        if let otherTitle = suggestions.otherTitle {
            var spec = textSpec(for: argument, collected: collected)
            let registry = registry
            spec.isValid = { text in registry.argumentValidation?(suggestions.source, text) ?? !text.trimmingCharacters(in: .whitespaces).isEmpty }
            extra.append(PaletteItem(
                id: "other", title: otherTitle, symbol: "square.and.pencil",
                section: PaletteSection(id: "argument", title: argument.title, order: 0),
                primary: PaletteCommand(id: "choose", title: PaletteStrings.choose, symbol: "return", effect: .textInput(spec))
            ))
        }
        return listPage(for: argument, options: options, collected: collected, extra: extra, pinnedCount: suggestions.pinned.count)
    }

    /// The captured object of the first kind the action targets.
    var capturedTarget: ActionTargetRef? {
        for kind in descriptor.targets {
            if let ref = captured.first(where: { $0.kind == kind }) { return ref }
        }
        return nil
    }

    func adding(_ argument: ActionArgument, _ text: String, to collected: ActionInvocation) -> ActionInvocation? {
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
            initialText: askedText(for: argument) ?? currentText(for: argument, of: collected.target) ?? "",
            skipsUnchangedText: argument.isTargetName || argument.isTargetDescription || askedText(for: argument) != nil,
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

    /// The text a handler's ask starts `argument`'s prompt from (the current name it read).
    private func askedText(for argument: ActionArgument) -> String? {
        argument.name == ask?.argument ? ask?.initialText : nil
    }

    /// The text `argument`'s prompt starts from: `target`'s current name
    /// (a rename) or description (an edit); nil for any other argument.
    private func currentText(for argument: ActionArgument, of target: ActionTargetRef?) -> String? {
        guard let target else { return nil }
        if argument.isTargetName { return targets?.title(of: target) }
        if argument.isTargetDescription { return targets?.currentDescription(of: target) }
        return nil
    }

    private func listPage(for argument: ActionArgument, options: [PaletteTargetOption], collected: ActionInvocation,
                          extra: [PaletteItem] = [], pinnedCount: Int? = nil) -> PalettePageSpec {
        let section = PaletteSection(id: "argument", title: argument.title, order: 0)
        var items = options.map { option in
            let next = adding(argument, option.id, to: collected)
            var item = PaletteItem(
                id: "option:\(option.id)",
                title: option.title,
                subtitle: option.subtitle,
                symbol: option.symbol ?? descriptor.symbol,
                section: section,
                isEnabled: next != nil && option.isEnabled,
                primary: PaletteCommand(
                    id: "choose",
                    title: PaletteStrings.choose,
                    symbol: "return",
                    effect: next.map { effect(collected: $0) } ?? .performKeepingOpen {}
                ),
                frecencyKey: "argument:\(descriptor.id.rawValue):\(argument.name):\(option.id)"
            )
            item.swatches = option.swatches
            item.ball = PaletteGroupColor.ball(action: descriptor.id, argument: argument.name, value: option.id)
            return item
        }
        // The value in effect (the current team or theme) reads "Current" and is the row the
        // step opens on, as in the settings pickers.
        let current = currentValue(of: argument, collected: collected).map { "option:\($0)" }
        if let current, let index = items.firstIndex(where: { $0.id == current }) {
            items[index].accessory = PaletteStrings.current
        }
        items.insert(contentsOf: extra, at: min(pinnedCount ?? items.count, items.count))
        var page = PalettePageSpec(
            id: "argument:\(descriptor.id.rawValue):\(argument.name)",
            title: Self.stepTitle(descriptor, argument),
            placeholder: PaletteStrings.chooseArgument(argument.title),
            symbol: descriptor.symbol,
            providers: [StaticPaletteProvider(id: "argument", items: items)],
            showsRecent: true
        )
        if let current, items.contains(where: { $0.id == current }) { page.emptyQuerySelectionID = current }
        return page
    }

    /// The value `argument` has now for the run's target (`ActionRegistry.choiceState`), when it is
    /// the action's one choice: with several arguments the state names none of them.
    private func currentValue(of argument: ActionArgument, collected: ActionInvocation) -> String? {
        guard descriptor.arguments.filter(asks).count == 1 else { return nil }
        return registry.choiceState?(descriptor.id, collected.target ?? capturedTarget)
    }

    /// The option value behind a list row (`option:<value>`).
    static func optionValue(_ item: PaletteItem) -> String? {
        item.id.hasPrefix("option:") ? String(item.id.dropFirst("option:".count)) : nil
    }

    /// An action title without the trailing ellipsis that marks it as asking for more ("New Group
    /// Chat…" is "New Group Chat"): "…" or "...", and the space some locales put before it ("Neuer
    /// Gruppenchat …").
    static func baseTitle(_ title: String) -> String {
        var text = Substring(title)
        if text.hasSuffix("…") { text = text.dropLast() } else if text.hasSuffix("...") { text = text.dropLast(3) }
        while let last = text.last, last.isWhitespace { text = text.dropLast() }
        return text.isEmpty ? title : String(text)
    }

    /// "Set Tab Group Color: Color" reads badly; use the action title for
    /// single-argument actions and "Title › Argument" otherwise.
    static func stepTitle(_ descriptor: ActionDescriptor, _ argument: ActionArgument) -> String {
        let base = baseTitle(descriptor.title)
        let required = descriptor.arguments.filter(\.isRequired)
        return required.count <= 1 ? base : "\(base) › \(argument.title)"
    }
}
