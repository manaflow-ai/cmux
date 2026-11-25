public import Foundation

/// When the app reads a tunable, which decides whether changing it takes
/// effect in this process.
///
/// A ``launch`` tunable is read once while the process starts (a Chromium
/// command-line switch, a flag an engine copies at init), so setting it
/// later changes the stored value and nothing else: the reader already has
/// the old one. `debug.tunables set` says so instead of reporting success,
/// and an A/B over such a key needs one launch per arm.
public enum TunableReadCadence: String, Sendable, CaseIterable {
    /// Read where it is used, so a change applies at once (nearly every tunable).
    case live
    /// Read once at process start; a change needs a relaunch.
    case launch
}

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
    /// When the app reads this tunable: ``TunableReadCadence/live`` unless
    /// the declaration says it is read once at launch.
    public let readCadence: TunableReadCadence

    public init(key: String, section: TunableSection, label: String, help: String, kind: TunableKind,
                defaultSource: DefaultSource, codeName: String? = nil,
                readCadence: TunableReadCadence = .live) {
        self.key = key
        self.section = section
        self.label = label
        self.help = help
        self.kind = kind
        self.defaultSource = defaultSource
        self.codeName = codeName
        self.readCadence = readCadence
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
/// label in Debug Settings. `tunableCases` are the options Debug Settings offers: every case unless a
/// type withholds some (an unreviewed family), while `allCases` stays every case so nothing walking
/// them skips one silently.
public nonisolated protocol TunableChoice: TunableValueConvertible, RawRepresentable, CaseIterable where RawValue == String {
    var tunableTitle: String { get }
    static var tunableCases: [Self] { get }
}

nonisolated extension TunableChoice {
    public init?(tunableValue: TunableValue) {
        guard let raw = tunableValue.choice, let value = Self(rawValue: raw) else { return nil }
        self = value
    }
    public var tunableValue: TunableValue { .choice(rawValue) }
    public static var tunableCases: [Self] { Array(allCases) }
    public static var tunableOptions: [TunableChoiceOption] {
        tunableCases.map { TunableChoiceOption(value: $0.rawValue, title: $0.tunableTitle) }
    }
}
