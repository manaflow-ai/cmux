public import Foundation

/// One tunable with a constant default: declared once, read anywhere.
///
/// ```swift
/// static let opacity = Tunable<Double>.number("drop.overlay.opacity", .dropOverlay, "Opacity",
///     help: "...", default: 1, range: 0...1, step: 0.05, unit: .fraction)
/// let alpha = opacity.value   // the override, else the default
/// ```
///
/// Reading is a lock and a dictionary lookup (nothing at all in builds
/// without Debug Settings, where the store never activates), safe from any
/// thread, and registers an Observation dependency on this one key, so a
/// view that reads it in a tracked scope updates live.
public nonisolated struct Tunable<Value: TunableValueConvertible>: Sendable {
    public let descriptor: TunableDescriptor
    public let defaultValue: Value

    public init(descriptor: TunableDescriptor, defaultValue: Value) {
        self.descriptor = descriptor
        self.defaultValue = defaultValue
    }

    public var key: String { descriptor.key }
    /// The override, else the default.
    public var value: Value { value(in: .shared) }
    /// The override, if any.
    public var override: Value? { override(in: .shared) }

    public func value(in store: TunableStore) -> Value { override(in: store) ?? defaultValue }
    public func override(in store: TunableStore) -> Value? { store.override(key).flatMap(Value.init(tunableValue:)) }
}

/// A tunable whose default code derives (a density metric): callers pass
/// the derived value and get the override instead when one is set.
public nonisolated struct DerivedTunable<Value: TunableValueConvertible>: Sendable {
    public let descriptor: TunableDescriptor

    public init(descriptor: TunableDescriptor) {
        self.descriptor = descriptor
    }

    public var key: String { descriptor.key }
    public var override: Value? { override(in: .shared) }
    public func override(in store: TunableStore) -> Value? { store.override(key).flatMap(Value.init(tunableValue:)) }
    /// The override, else `computed`.
    public func resolve(_ computed: Value, in store: TunableStore = .shared) -> Value { override(in: store) ?? computed }
}

// MARK: Declarations

nonisolated extension Tunable where Value: BinaryFloatingPoint {
    public static func number(
        _ key: String, _ section: TunableSection, _ label: String, help: String, default value: Value,
        range: ClosedRange<Double>, step: Double, unit: TunableUnit, code: String? = nil
    ) -> Tunable {
        Tunable(descriptor: TunableDescriptor(key: key, section: section, label: label, help: help,
                                              kind: .number(range: range, step: step, unit: unit),
                                              defaultSource: .fixed(.number(Double(value))), codeName: code),
                defaultValue: value)
    }
}

nonisolated extension Tunable where Value == Bool {
    public static func toggle(_ key: String, _ section: TunableSection, _ label: String, help: String,
                              default value: Bool, code: String? = nil) -> Tunable {
        Tunable(descriptor: TunableDescriptor(key: key, section: section, label: label, help: help, kind: .bool,
                                              defaultSource: .fixed(.bool(value)), codeName: code),
                defaultValue: value)
    }
}

nonisolated extension Tunable where Value == TunableColor {
    public static func color(_ key: String, _ section: TunableSection, _ label: String, help: String,
                             default value: TunableColor, code: String? = nil) -> Tunable {
        Tunable(descriptor: TunableDescriptor(key: key, section: section, label: label, help: help, kind: .color,
                                              defaultSource: .fixed(.color(value)), codeName: code),
                defaultValue: value)
    }
}

nonisolated extension Tunable where Value == SpringParameters {
    public static func spring(_ key: String, _ section: TunableSection, _ label: String, help: String,
                              default value: SpringParameters, code: String? = nil) -> Tunable {
        Tunable(descriptor: TunableDescriptor(key: key, section: section, label: label, help: help, kind: .spring,
                                              defaultSource: .fixed(.spring(value)), codeName: code),
                defaultValue: value)
    }
}

nonisolated extension Tunable where Value: TunableChoice {
    public static func choice(_ key: String, _ section: TunableSection, _ label: String, help: String,
                              default value: Value, code: String? = nil) -> Tunable {
        Tunable(descriptor: TunableDescriptor(key: key, section: section, label: label, help: help,
                                              kind: .choice(Value.tunableOptions),
                                              defaultSource: .fixed(value.tunableValue), codeName: code),
                defaultValue: value)
    }
}

nonisolated extension DerivedTunable where Value: BinaryFloatingPoint {
    /// `derive` computes the default the app uses without an override.
    public static func number(
        _ key: String, _ section: TunableSection, _ label: String, help: String,
        range: ClosedRange<Double>, step: Double, unit: TunableUnit, code: String? = nil,
        derive: @escaping @MainActor @Sendable () -> Value
    ) -> DerivedTunable {
        DerivedTunable(descriptor: TunableDescriptor(key: key, section: section, label: label, help: help,
                                                     kind: .number(range: range, step: step, unit: unit),
                                                     defaultSource: .derived({ .number(Double(derive())) }), codeName: code))
    }
}

/// A points value code computes from other tokens (`Metrics.space6 +
/// Metrics.space2`), overridable in Debug Settings. The expression lives
/// once, in `derive`; `value` is the override or the computed default.
public nonisolated struct ComputedTunable: Sendable {
    public let tunable: DerivedTunable<CGFloat>
    public let derive: @MainActor @Sendable () -> CGFloat

    public init(_ key: String, _ section: TunableSection, _ label: String, help: String, range: ClosedRange<Double>,
                step: Double = 0.5, unit: TunableUnit = .points, code: String? = nil,
                derive: @escaping @MainActor @Sendable () -> CGFloat) {
        self.derive = derive
        tunable = .number(key, section, label, help: help, range: range, step: step, unit: unit, code: code, derive: derive)
    }

    @MainActor public var value: CGFloat { tunable.resolve(derive()) }
    public var descriptor: TunableDescriptor { tunable.descriptor }
}
