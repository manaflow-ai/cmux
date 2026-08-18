/// One manifest entry whose executable rules are prepared once per accepted
/// catalog generation.
struct CmuxAgentCompiledManifestEntry: Sendable {
    let entry: CmuxAgentManifestEntry
    let processMatchers: [CmuxAgentCompiledProcessMatcher]
    let stateRules: [CmuxAgentCompiledStateRule]
    let hasScreenConditions: Bool
    let hasScreenContainsConditions: Bool
    let hasScreenRegexConditions: Bool
    let hasOSCConditions: Bool

    init(entry: CmuxAgentManifestEntry) {
        self.entry = entry
        // Bundled expressions are app-owned, strictly validated, and bounded
        // by input/work limits. User expressions retain ICU progress callbacks
        // so a future validator bug still cannot monopolize a scan.
        let reportsRegexProgress = entry.source == .user
        self.processMatchers = entry.manifest.process.matchers.map {
            CmuxAgentCompiledProcessMatcher(
                matcher: $0,
                reportsRegexProgress: reportsRegexProgress
            )
        }
        self.stateRules = entry.manifest.states.map {
            CmuxAgentCompiledStateRule(
                rule: $0,
                reportsRegexProgress: reportsRegexProgress
            )
        }
        self.hasScreenContainsConditions = entry.manifest.states.contains {
            !$0.screenContains.isEmpty
        }
        self.hasScreenRegexConditions = entry.manifest.states.contains {
            !$0.screenRegex.isEmpty
        }
        self.hasScreenConditions = hasScreenContainsConditions
            || hasScreenRegexConditions
        self.hasOSCConditions = entry.manifest.states.contains { !$0.osc.isEmpty }
    }
}
