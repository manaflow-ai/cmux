/// A typed handle to one param of a feature: Chromium's `base::FeatureParam`
/// (base/metrics/field_trial_params.h).
///
/// The name, type, default and bounds come from the registry
/// (`schemas/features/features.d/<name>.json`, ``Feature/params``); the handle
/// only carries the param's slot, so ``FeatureParamList/value(_:)`` is one
/// array load, as Chrome's `BASE_FEATURE_PARAM` caches its value after the
/// first read. Declare a handle once, next to the code that reads it:
///
/// ```swift
/// static let syncDeadline = FeatureParam<Duration>(.cefLayerHosting, "syncDeadline")
/// ```
///
/// A name the feature does not declare, or a `Value` that does not match the
/// declared type, stops a debug build; in Release that handle is unbound and
/// reads `Value`'s ``FeatureParamType/featureParamZero``.
public nonisolated struct FeatureParam<Value: FeatureParamType>: Sendable, Hashable {
    /// The feature that declares the param.
    public let feature: Feature
    /// The param's position in ``Feature/params``, or nil when unbound.
    public let index: Int?
    /// The param's slot among every param of the registry, in registry
    /// order, or nil when unbound.
    public let slot: Int?
    /// The registry default, read when the snapshot has no value for the slot.
    public let declaredDefault: Value

    /// The handle of `feature`'s param `name` in `registry` (the generated
    /// registry unless a test passes its own).
    public init(_ feature: Feature, _ name: String, in registry: FeatureRegistry = FeatureRegistry()) {
        self.feature = feature
        let found = feature.params.firstIndex { $0.name == name }
        let declared = found.map { feature.params[$0].value }
        let bound = registry.contains(feature) && declared.map(Value.accepts) == true
        assert(bound, "param \(feature.name).\(name) is \(declared?.typeName ?? "not declared"), not a \(Value.self) param of this registry")
        guard bound, let index = found, let value = declared.flatMap({ Value(featureParam: $0.defaultScalar) }) else {
            self.index = nil
            slot = nil
            declaredDefault = Value.featureParamZero
            return
        }
        self.index = index
        slot = registry.features[..<feature.index].reduce(index) { $0 + $1.params.count }
        declaredDefault = value
    }

    /// The registry's declaration of the param, or nil when unbound.
    public var spec: FeatureParamSpec? { index.map { feature.params[$0] } }
}

/// A Swift type a ``FeatureParam`` reads: `Int` (`int`), `Double` (`double`,
/// or `duration` in seconds), `Duration` (`duration`, to the microsecond) and
/// `Bool` (`bool`).
public protocol FeatureParamType: Sendable, Hashable {
    /// The value of an unbound handle: zero or false.
    static var featureParamZero: Self { get }
    /// Whether a param declared as `value` reads as this type.
    static func accepts(_ value: FeatureParamValue) -> Bool
    /// A resolved value as this type, or nil for a scalar of another type.
    init?(featureParam scalar: FeatureParamValue.Scalar)
}

extension Int: FeatureParamType {
    public static var featureParamZero: Int { 0 }

    public static func accepts(_ value: FeatureParamValue) -> Bool {
        if case .int = value { return true }
        return false
    }

    public init?(featureParam scalar: FeatureParamValue.Scalar) {
        guard case let .int(value) = scalar else { return nil }
        self = value
    }
}

extension Double: FeatureParamType {
    public static var featureParamZero: Double { 0 }

    public static func accepts(_ value: FeatureParamValue) -> Bool {
        switch value {
        case .double, .duration: true
        case .int, .bool: false
        }
    }

    public init?(featureParam scalar: FeatureParamValue.Scalar) {
        guard case let .double(value) = scalar else { return nil }
        self = value
    }
}

extension Duration: FeatureParamType {
    public static var featureParamZero: Duration { .zero }

    public static func accepts(_ value: FeatureParamValue) -> Bool {
        if case .duration = value { return true }
        return false
    }

    /// Whole microseconds, as ``Feature/durationParam(_:)``: `.seconds(0.2)`
    /// would carry the double's error into the attoseconds.
    public init?(featureParam scalar: FeatureParamValue.Scalar) {
        guard case let .double(seconds) = scalar else { return nil }
        self = .microseconds(Int64((seconds * 1_000_000).rounded()))
    }
}

extension Bool: FeatureParamType {
    public static var featureParamZero: Bool { false }

    public static func accepts(_ value: FeatureParamValue) -> Bool {
        if case .bool = value { return true }
        return false
    }

    public init?(featureParam scalar: FeatureParamValue.Scalar) {
        guard case let .bool(value) = scalar else { return nil }
        self = value
    }
}

extension FeatureParamValue {
    /// A resolved param value. A `duration` is `.double` seconds.
    public enum Scalar: Sendable, Hashable, CustomStringConvertible {
        case int(Int)
        case double(Double)
        case bool(Bool)

        public var description: String {
            switch self {
            case let .int(value): String(value)
            case let .double(value): String(value)
            case let .bool(value): String(value)
            }
        }
    }

    /// The registry name of the type: `int`, `double`, `duration` or `bool`.
    public var typeName: String {
        switch self {
        case .int: "int"
        case .double: "double"
        case .duration: "duration"
        case .bool: "bool"
        }
    }

    /// The declared default.
    public var defaultScalar: FeatureParamValue.Scalar {
        switch self {
        case let .int(value, _, _): .int(value)
        case let .double(value, _, _), let .duration(value, _, _): .double(value)
        case let .bool(value): .bool(value)
        }
    }

    /// `text` as a value of this type inside the declared bounds.
    public func parse(_ text: String) throws(FeatureParamList.Rejection.Reason) -> FeatureParamValue.Scalar {
        switch self {
        case let .int(_, min, max):
            guard let value = Int(text) else { throw .malformed(expected: "an int") }
            guard value >= min, value <= max else { throw .outOfRange(min: String(min), max: String(max)) }
            return .int(value)
        case let .double(_, min, max), let .duration(_, min, max):
            guard let value = Double(text), value.isFinite else { throw .malformed(expected: "a finite number") }
            guard value >= min, value <= max else { throw .outOfRange(min: String(min), max: String(max)) }
            return .double(value)
        case .bool:
            switch text {
            case "true": return .bool(true)
            case "false": return .bool(false)
            default: throw .malformed(expected: "true or false")
            }
        }
    }
}
