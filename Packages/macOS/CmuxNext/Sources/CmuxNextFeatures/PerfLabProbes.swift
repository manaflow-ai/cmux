#if DEBUG || CMUX_BENCH_HOOKS
/// What a bench build reports about the perf lab's kill probe at launch (``Feature/perfLabKillProbe``, done check
/// 13): the kill probe changes nothing, so its value and source are the whole proof that a signed flags document
/// reached the app's ``FeatureList``.
public struct PerfLabFeatureReport: Sendable, Equatable {
    public let killProbe: Feature.Resolution

    public init(_ features: FeatureList) {
        killProbe = features.resolution(of: .perfLabKillProbe)
    }

    /// `perf lab: perfLabKillProbe=off source=remote`.
    public var line: String {
        "perf lab: \(Feature.perfLabKillProbe.name)=\(killProbe)"
    }
}
#endif
