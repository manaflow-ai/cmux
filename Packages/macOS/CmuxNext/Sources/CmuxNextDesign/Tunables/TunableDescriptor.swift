public import Foundation

/// Everything the Debug Settings window and the exports know about one
/// tunable, without its Swift value type.
public nonisolated struct TunableDescriptor: Sendable, Identifiable {
    /// Where the default comes from: a constant, or a value code derives
    /// (density metrics), read on the main actor.
    public enum DefaultSource: Sendable {
        case fixed(TunableValue)
        case derived(@MainActor @Sendable () -> TunableValue)
    }

    /// Stable dotted key (`drop.overlay.style`), the override file's key.
    public let key: String
    public let section: TunableSection
    public let label: String
    public let help: String
    public let kind: TunableKind
    public let defaultSource: DefaultSource
    /// The Swift name that holds the default (`MotionSpring.move`), for
    /// "Copy as Swift defaults". Nil uses the key.
    public let codeName: String?

    public init(key: String, section: TunableSection, label: String, help: String, kind: TunableKind,
                defaultSource: DefaultSource, codeName: String? = nil) {
        self.key = key
        self.section = section
        self.label = label
        self.help = help
        self.kind = kind
        self.defaultSource = defaultSource
        self.codeName = codeName
    }

    public var id: String { key }

    /// The default the app uses without an override (derived ones for the
    /// current density).
    @MainActor public var defaultValue: TunableValue {
        switch defaultSource {
        case .fixed(let value): value
        case .derived(let make): make()
        }
    }

    /// `value` made valid for this tunable, or nil when it does not fit.
    public func clamp(_ value: TunableValue) -> TunableValue? { kind.clamp(value) }
}

/// A Swift type a tunable can hold.
public nonisolated protocol TunableValueConvertible: Sendable, Equatable {
    init?(tunableValue: TunableValue)
    var tunableValue: TunableValue { get }
}

nonisolated extension Double: TunableValueConvertible {
    public init?(tunableValue: TunableValue) {
        guard let number = tunableValue.number else { return nil }
        self = number
    }
    public var tunableValue: TunableValue { .number(self) }
}

nonisolated extension CGFloat: TunableValueConvertible {
    public init?(tunableValue: TunableValue) {
        guard let number = tunableValue.number else { return nil }
        self = CGFloat(number)
    }
    public var tunableValue: TunableValue { .number(Double(self)) }
}

nonisolated extension Bool: TunableValueConvertible {
    public init?(tunableValue: TunableValue) {
        guard let flag = tunableValue.bool else { return nil }
        self = flag
    }
    public var tunableValue: TunableValue { .bool(self) }
}

nonisolated extension TunableColor: TunableValueConvertible {
    public init?(tunableValue: TunableValue) {
        guard let color = tunableValue.color else { return nil }
        self = color
    }
    public var tunableValue: TunableValue { .color(self) }
}

nonisolated extension SpringParameters: TunableValueConvertible {
    public init?(tunableValue: TunableValue) {
        guard let spring = tunableValue.spring else { return nil }
        self = spring
    }
    public var tunableValue: TunableValue { .spring(self) }
}

/// A string enum a choice tunable picks from. `tunableTitle` is the option
/// label in Debug Settings.
public nonisolated protocol TunableChoice: TunableValueConvertible, RawRepresentable, CaseIterable where RawValue == String {
    var tunableTitle: String { get }
}

nonisolated extension TunableChoice {
    public init?(tunableValue: TunableValue) {
        guard let raw = tunableValue.choice, let value = Self(rawValue: raw) else { return nil }
        self = value
    }
    public var tunableValue: TunableValue { .choice(rawValue) }
    public static var tunableOptions: [TunableChoiceOption] {
        allCases.map { TunableChoiceOption(value: $0.rawValue, title: $0.tunableTitle) }
    }
}
