public import CmuxNextFeatures

extension HangReport.FeatureState {
    /// A launch's ``FeatureFieldState`` as a hang report carries it.
    public init(_ state: FeatureFieldState) {
        self.init(hash: state.hash, nonDefault: state.nonDefault.map {
            HangReport.FeatureEntry(name: $0.name, state: $0.state, source: $0.source.description)
        })
    }
}
