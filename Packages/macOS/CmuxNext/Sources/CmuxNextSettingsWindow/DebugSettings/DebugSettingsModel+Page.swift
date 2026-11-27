public import CmuxNextDesign
public import CmuxNextSettings
import Foundation

// The React Debug Settings page (cmux-page://cmux.debug-settings/) and the `debug.tunables` verb
// read the registry through these: the page renders every tunable from `pageState` (sections,
// rows, the control each kind gets, values, defaults and their display text), so a tunable a module
// declares appears with no page code. The model stays the one owner of the view state (search,
// selection, notice); the page is a view that sends intents.

extension DebugSettingsSelection {
    /// `all`, `changed`, or a section id (the page route and the verb's `section`).
    public init(id: String) {
        switch id {
        case "all": self = .all
        case "changed": self = .changed
        default: self = .section(id)
        }
    }

    public var id: String {
        switch self {
        case .all: "all"
        case .changed: "changed"
        case .section(let id): id
        }
    }
}

extension DebugSettingsModel {
    /// Everything the page draws: the view state, the sidebar, and the visible rows by section.
    /// Color choices carry swatches in the theme Debug Settings follows (`followTheme`).
    public func pageState() -> JSONValue {
        let tokens = SettingsTheme.shared.tokens
        let overrides = store.overrides
        let sections: [JSONValue] = sections.map { section in
            let members = descriptors.filter { $0.section.id == section.id }
            return [
                "id": .string(section.id), "title": .string(section.title), "symbol": .string(section.symbol),
                "count": JSONValue(members.count),
                "changed": JSONValue(members.count { Self.differs($0, overrides) }),
            ]
        }
        let groups: [JSONValue] = groupedVisible.map { group in
            ["id": .string(group.section.id), "title": .string(group.section.title),
             "rows": .array(group.rows.map { pageRow($0, overrides: overrides, tokens: tokens) })]
        }
        var state: [String: JSONValue] = [
            "query": .string(query), "selection": .string(selection.id),
            "total": JSONValue(descriptors.count), "changed": JSONValue(changedCount), "visible": JSONValue(visible.count),
            "sections": .array(sections), "groups": .array(groups),
        ]
        if let notice { state["notice"] = .string(notice) }
        return .object(state)
    }

    /// Reads everything ``pageState()`` depends on, inside `withObservationTracking`: the view
    /// state, every override (the store revision) and the theme of the color swatches.
    public func touchPageState() {
        _ = query
        _ = selection
        _ = notice
        _ = store.revision
        _ = SettingsTheme.shared.tokens
    }

    /// One row: the descriptor, the control of its kind, the value and the default.
    func pageRow(_ descriptor: TunableDescriptor, overrides: [String: TunableValue], tokens: ThemeTokens) -> JSONValue {
        let defaultValue = descriptor.defaultValue
        let value = overrides[descriptor.key] ?? defaultValue
        return [
            "key": .string(descriptor.key), "section": .string(descriptor.section.id), "label": .string(descriptor.label),
            "help": .string(descriptor.help), "control": Self.control(descriptor.kind, tokens: tokens),
            "value": Self.json(value), "default": Self.json(defaultValue), "changed": .bool(value != defaultValue),
            "value_text": .string(DebugSettingsStrings.display(value, kind: descriptor.kind)),
            "default_text": .string(DebugSettingsStrings.defaultIs(DebugSettingsStrings.display(defaultValue, kind: descriptor.kind))),
        ]
    }

    /// Sets search and selection from the page (`view.set {query?, selection?}`). A selection
    /// clears the search, as a sidebar click does.
    public func applyView(_ params: [String: JSONValue]) {
        if let selection = params["selection"]?.stringValue {
            query = ""
            self.selection = DebugSettingsSelection(id: selection)
        }
        if let query = params["query"]?.stringValue { self.query = query }
    }

    /// Sets `key` from a JSON value (null resets). Returns false when the key is unknown or the
    /// value does not fit its kind.
    @discardableResult
    public func set(key: String, json: JSONValue?) -> Bool {
        guard let descriptor = descriptors.first(where: { $0.key == key }) else { return false }
        guard let json, json != .null else {
            reset(descriptor)
            return true
        }
        guard let value = Self.tunableValue(json, kind: descriptor.kind), descriptor.clamp(value) != nil else { return false }
        set(descriptor, value)
        return true
    }

    /// The control a kind gets, with its limits (number range and step, choice options, color
    /// swatches, spring limits).
    static func control(_ kind: TunableKind, tokens: ThemeTokens) -> JSONValue {
        switch kind {
        case let .number(range, step, unit):
            return ["type": "number", "min": .number(range.lowerBound), "max": .number(range.upperBound),
                    "step": .number(step), "unit": .string(unit.rawValue)]
        case .bool:
            return ["type": "bool", "on": .string(DebugSettingsStrings.on), "off": .string(DebugSettingsStrings.off)]
        case .choice(let options):
            return ["type": "choice", "options": .array(options.map { ["value": .string($0.value), "title": .string($0.title)] })]
        case .color:
            return ["type": "color", "options": .array(TunableColor.allCases.map { color in
                ["value": .string(color.rawValue), "title": .string(color.rawValue),
                 "swatch": .string(color.resolve(in: tokens).withAlpha(1).description)]
            })]
        case .spring:
            // The same slider limits as the Swift control (a tighter range than the clamp).
            return ["type": "spring",
                    "response": ["min": .number(TunableKind.springResponseRange.lowerBound), "max": 1, "step": 0.005,
                                 "unit": .string(TunableUnit.seconds.rawValue), "label": .string(DebugSettingsStrings.response)],
                    "damping": ["min": .number(TunableKind.springDampingRange.lowerBound), "max": 1.2, "step": 0.01,
                                "unit": .string(TunableUnit.multiplier.rawValue), "label": .string(DebugSettingsStrings.damping)]]
        }
    }

    /// A value as JSON: numbers, flags, choice and color raw values, springs as an object.
    public static func json(_ value: TunableValue) -> JSONValue {
        switch value {
        case .number(let number): .number(number)
        case .bool(let flag): .bool(flag)
        case .choice(let raw): .string(raw)
        case .color(let color): .string(color.rawValue)
        case .spring(let spring): ["response": .number(spring.response), "dampingFraction": .number(spring.dampingFraction)]
        }
    }

    /// A JSON value as a value of `kind`, or nil when it has the wrong shape (not yet clamped).
    public static func tunableValue(_ json: JSONValue, kind: TunableKind) -> TunableValue? {
        switch kind {
        case .number: json.doubleValue.map(TunableValue.number)
        case .bool: json.boolValue.map(TunableValue.bool)
        case .choice: json.stringValue.map(TunableValue.choice)
        case .color: json.stringValue.flatMap(TunableColor.init(rawValue:)).map(TunableValue.color)
        case .spring:
            json["response"]?.doubleValue.flatMap { response in
                json["dampingFraction"]?.doubleValue.map { .spring(SpringParameters(response: response, dampingFraction: $0)) }
            }
        }
    }

    private static func differs(_ descriptor: TunableDescriptor, _ overrides: [String: TunableValue]) -> Bool {
        guard let value = overrides[descriptor.key] else { return false }
        return value != descriptor.defaultValue
    }
}
