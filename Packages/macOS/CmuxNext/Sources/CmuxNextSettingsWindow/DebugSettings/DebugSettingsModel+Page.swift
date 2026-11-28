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

    /// Whether the running app is using the value a tunable's row shows.
    ///
    /// A missing read is not a negative answer: nothing has read a launch-time key yet, so which
    /// value this process ends up with is `unknown` until that read happens, not `no`
    /// (docs/handbook/missing-read-counted-as-a-value.md).
    public enum AppliesState: String, Sendable {
        /// The app is using this value: a live key, or a launch-time key whose launch read answered it.
        case yes
        /// The app is using another value: a launch-time key read at launch with a different one.
        case no
        /// A launch-time key nothing has read this launch: which value is in use is not known yet.
        case unknown

        /// `yes`/`no` as a flag; nil for `unknown`, which is not a value.
        public var applies: Bool? {
            switch self {
            case .yes: true
            case .no: false
            case .unknown: nil
            }
        }
    }

    /// Whether the stored value of `descriptor` is the one this process is using.
    ///
    /// It reports the value, not the cadence: a launch-time key whose stored value is the one this
    /// process read at launch (a fresh launch for an arm, or a `set` back to the launch value) does
    /// apply. Reporting the cadence alone would call a correctly relaunched arm unapplied, which is
    /// the mislabelling this answer exists to prevent.
    public static func appliesState(_ descriptor: TunableDescriptor, _ store: TunableStore) -> AppliesState {
        guard descriptor.readCadence == .launch else { return .yes }
        guard store.wasReadAtLaunch(descriptor.key) else { return .unknown }
        let launchValue = store.launchReadValue(descriptor.key) ?? descriptor.defaultValue
        return launchValue == (store.override(descriptor.key) ?? descriptor.defaultValue) ? .yes : .no
    }

    /// One tunable as the `debug.tunables` verb reports it: value, default, whether it differs,
    /// and when the app reads it.
    ///
    /// `read_cadence` lets automation (an A/B harness) tell a key it can change now from one this
    /// process read at launch. `applies_state` is `yes`, `no` or `unknown`, and `applies` carries
    /// the first two as a flag, so a caller cannot read success into a change that did nothing (the
    /// trap cmux#45709 shipped). `launch_value` carries what the launch read answered.
    ///
    /// A launch-time key nothing has read this launch is `unknown`, with no `applies` field at all:
    /// a read still ahead of it will take the stored value, and a read already past will not, and
    /// the row does not know which. Reporting that as `applies: false` would answer a question
    /// nobody has asked the app yet.
    public static func tunableRow(_ descriptor: TunableDescriptor, _ store: TunableStore) -> JSONValue {
        let value = store.override(descriptor.key) ?? descriptor.defaultValue
        let launch = descriptor.readCadence == .launch
        let read = launch && store.wasReadAtLaunch(descriptor.key)
        let launchValue = read ? (store.launchReadValue(descriptor.key) ?? descriptor.defaultValue) : nil
        let state = appliesState(descriptor, store)
        var fields: [String: JSONValue] = [
            "key": .string(descriptor.key), "section": .string(descriptor.section.id), "label": .string(descriptor.label),
            "value": json(value), "default": json(descriptor.defaultValue), "changed": .bool(isChanged(descriptor, store)),
            "read_cadence": .string(descriptor.readCadence.rawValue),
            "applies_state": .string(state.rawValue),
        ]
        if let applies = state.applies { fields["applies"] = .bool(applies) }
        if let launchValue { fields["launch_value"] = json(launchValue) }
        switch state {
        case .yes: break
        case .no:
            fields["applies_why"] = .string(
                "\(descriptor.key) is read once while the app starts, so this launch keeps the value it started with (see launch_value); relaunch to use the stored one")
        case .unknown:
            fields["applies_why"] = .string(
                "\(descriptor.key) is read once while the app starts and nothing has read it this launch, so whether the stored value is in use is unknown: a read still ahead takes it, and a relaunch makes it certain")
        }
        return .object(fields)
    }

    /// Whether the store holds a value for `descriptor` that differs from its default.
    public static func isChanged(_ descriptor: TunableDescriptor, _ store: TunableStore) -> Bool {
        guard let value = store.override(descriptor.key) else { return false }
        return value != descriptor.defaultValue
    }
}
