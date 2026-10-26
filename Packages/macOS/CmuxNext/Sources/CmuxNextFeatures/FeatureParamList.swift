import OSLog

/// The resolved value of every feature param, built once next to the
/// ``FeatureList`` by the composition root and immutable after that, so
/// ``value(_:)`` is one array load and needs no lock.
///
/// Resolution, highest first:
/// 1. a local Debug override, DEV and NIGHTLY only
/// 2. the signed remote document's value
/// 3. the registry default
///
/// A param of a feature that is off reads its default, as Chrome's
/// `GetFieldTrialParamsByFeature` returns no params for a disabled feature.
/// Input values are text, as Chrome's `FieldTrialParams`: an `int` is a
/// decimal integer, a `double` or `duration` (seconds) a finite number, a
/// `bool` `true` or `false`. A value that does not parse or lies outside the
/// declared bounds is rejected, reported to `report` (by default the unified
/// log) and kept in ``rejections``, and the next input decides; a remote value
/// for a name the registry does not declare is rejected the same way.
public nonisolated final class FeatureParamList: Sendable {
    /// The feature snapshot whose on/off values gate the params.
    public let features: FeatureList
    /// Every rejected value: declared params in registry order (remote
    /// before local), then undeclared remote names, sorted.
    public let rejections: [Rejection]
    /// `(feature index, param index)` per slot, in registry order.
    private let layout: [(feature: Int, param: Int)]
    @usableFromInline let resolutions: ContiguousArray<Resolution>

    /// Resolves every param of `features`' registry once. `remote` maps a
    /// feature name to its params' text (the signed document, already
    /// filtered by safe mode). `local` is asked only when `features`' channel
    /// allows local overrides, once per param of a feature that is on.
    public init(
        features: FeatureList,
        remote: [String: [String: String]] = [:],
        local: (any FeatureParamLocalOverrideProvider)? = nil,
        report: (Rejection) -> Void = FeatureParamList.logRejection
    ) {
        let local = features.channel.allowsLocalOverrides ? local : nil
        let registry = features.registry
        var layout: [(feature: Int, param: Int)] = []
        var resolutions = ContiguousArray<Resolution>()
        var rejections: [Rejection] = []
        for feature in registry.features {
            let enabled = features.isEnabled(feature)
            for (index, spec) in feature.params.enumerated() {
                func accepted(_ text: String, from source: Feature.Source) -> Resolution? {
                    do throws(Rejection.Reason) {
                        return try Resolution(value: spec.value.parse(text), source: source)
                    } catch {
                        rejections.append(Rejection(feature: feature.name, param: spec.name, text: text, source: source, reason: error))
                        return nil
                    }
                }
                // A remote value is checked even while the feature is off, so a bad document is reported at once.
                let remoteValue = remote[feature.name]?[spec.name].flatMap { accepted($0, from: .remote) }
                let localValue = enabled ? local?.localOverride(for: spec, of: feature).flatMap { accepted($0, from: .local) } : nil
                let fallback = Resolution(value: spec.value.defaultScalar, source: .channelDefault)
                layout.append((feature: feature.index, param: index))
                resolutions.append(enabled ? localValue ?? remoteValue ?? fallback : fallback)
            }
        }
        rejections += Self.undeclared(in: remote, registry: registry)
        for rejection in rejections {
            report(rejection)
        }
        self.features = features
        self.layout = layout
        self.resolutions = resolutions
        self.rejections = rejections
    }

    /// The value of `param`. One array load; `param` must be a handle of
    /// this list's registry (an unbound handle reads its zero value).
    @inlinable
    public func value<Value>(_ param: FeatureParam<Value>) -> Value {
        resolution(of: param).flatMap { Value(featureParam: $0.value) } ?? param.declaredDefault
    }

    /// The value of `param` and the input that decided it, or nil for an
    /// unbound handle.
    @inlinable
    public func resolution<Value>(of param: FeatureParam<Value>) -> Resolution? {
        assert(features.registry.contains(param.feature), "feature \(param.feature.name) is not declared in this list's registry")
        guard let slot = param.slot, resolutions.indices.contains(slot) else { return nil }
        return resolutions[slot]
    }

    /// Every param with its resolution, in registry order (Labs page,
    /// `cmux settings feature-flags`, reports).
    public var entries: [(feature: Feature, spec: FeatureParamSpec, resolution: Resolution)] {
        zip(layout, resolutions).map { slot, resolution in
            let feature = features.registry.features[slot.feature]
            return (feature: feature, spec: feature.params[slot.param], resolution: resolution)
        }
    }

    /// Writes `rejection` to the unified log: the default `report`.
    public static func logRejection(_ rejection: Rejection) {
        Logger(subsystem: "com.cmuxterm.app.next", category: "features")
            .error("feature param rejected: \(rejection.description, privacy: .public)")
    }

    /// Remote values for a feature or a param the registry does not declare.
    private static func undeclared(in remote: [String: [String: String]], registry: FeatureRegistry) -> [Rejection] {
        var rejections: [Rejection] = []
        for (name, params) in remote.sorted(by: { $0.key < $1.key }) {
            let feature = registry.feature(named: name)
            for (param, text) in params.sorted(by: { $0.key < $1.key }) where !(feature?.params.contains { $0.name == param } ?? false) {
                rejections.append(Rejection(
                    feature: name,
                    param: param,
                    text: text,
                    source: .remote,
                    reason: feature == nil ? .unknownFeature : .unknownParam
                ))
            }
        }
        return rejections
    }
}

extension FeatureParamList {
    /// A resolved param and the input that decided it: ``Feature/Source/local``,
    /// ``Feature/Source/remote`` or ``Feature/Source/channelDefault``.
    public struct Resolution: Sendable, Hashable, CustomStringConvertible {
        public let value: FeatureParamValue.Scalar
        public let source: Feature.Source

        public init(value: FeatureParamValue.Scalar, source: Feature.Source) {
            self.value = value
            self.source = source
        }

        /// `0.05 source=remote`, the form `cmux settings feature-flags` prints.
        public var description: String { "\(value) source=\(source)" }
    }

    /// A param value an input gave that the snapshot did not use, and why.
    public struct Rejection: Sendable, Hashable, CustomStringConvertible {
        /// Why a value was rejected.
        public enum Reason: Error, Sendable, Hashable, CustomStringConvertible {
            /// The registry declares no feature of that name.
            case unknownFeature
            /// The feature declares no param of that name.
            case unknownParam
            /// The text is not a value of the param's type (`int`, `double`, `duration` or `bool`).
            case malformed(expected: String)
            /// A number outside the declared bounds, which are inclusive.
            case outOfRange(min: String, max: String)

            public var description: String {
                switch self {
                case .unknownFeature: "unknown feature"
                case .unknownParam: "unknown param"
                case let .malformed(expected): "not \(expected)"
                case let .outOfRange(min, max): "outside \(min)...\(max)"
                }
            }
        }

        public let feature: String
        public let param: String
        /// The rejected text, as the input gave it.
        public let text: String
        /// ``Feature/Source/local`` or ``Feature/Source/remote``.
        public let source: Feature.Source
        public let reason: Reason

        public init(feature: String, param: String, text: String, source: Feature.Source, reason: Reason) {
            self.feature = feature
            self.param = param
            self.text = text
            self.source = source
            self.reason = reason
        }

        /// `cefLayerHosting.syncDeadline="5" source=remote: outside 0.0...1.0`.
        public var description: String { "\(feature).\(param)=\"\(text)\" source=\(source): \(reason)" }
    }
}

/// Local Debug overrides of params (DEV and NIGHTLY only): the App adapts
/// `TunableStore` to it for the numeric tunables a param replaced. The text
/// has the remote document's form (``FeatureParamList``).
public protocol FeatureParamLocalOverrideProvider: Sendable {
    /// The value the developer chose for `feature`'s param `spec`, or nil for none.
    func localOverride(for spec: FeatureParamSpec, of feature: Feature) -> String?
}

