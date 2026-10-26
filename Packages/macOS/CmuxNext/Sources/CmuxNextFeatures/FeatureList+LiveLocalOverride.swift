nonisolated extension FeatureList {
    /// `feature` with `local`, a Debug override read at the call (a tunable the feature `replaces`),
    /// in step 3 of the resolution order: managed policy and the environment lists still win, `local`
    /// beats the Labs page's launch choice, the remote document, the trial arm and the channel default,
    /// and Release never asks for it, as Chromium's about:flags choices reach `base::FeatureList` below
    /// the command line (base/feature_list.cc, `InitFromCommandLine` first). A caller asks once per use
    /// (a spring's or a slide's start), so a Debug change applies to the next use while the feature
    /// itself stays resolved once per launch.
    public func isEnabled(_ feature: Feature, overriddenBy local: @autoclosure () -> Bool?) -> Bool {
        let resolved = resolution(of: feature)
        guard channel.allowsLocalOverrides, resolved.source != .policy, resolved.source != .environment,
              let value = local() else { return resolved.isEnabled }
        return value
    }
}
