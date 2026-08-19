/// Data-driven pressure patterns for one managed agent provider.
struct AgentContextProviderDefinition: Sendable {
    let patterns: [AgentContextPressurePattern]
    let maximumMarkerLength: Int

    init(patterns: [AgentContextPressurePattern]) {
        self.patterns = patterns
        self.maximumMarkerLength = patterns
            .flatMap(\.markers)
            .map(\.count)
            .max() ?? 0
    }

    private static let longThreadWarning = AgentContextPressurePattern(
        signal: .longThreadWarning,
        markers: [
            "long threads and multiple compactions can cause the model to be less accurate. start a new thread when possible to keep threads small and targeted",
        ],
        eventThreshold: 1
    )

    static func definition(for provider: AgentContextProvider) -> Self {
        switch provider {
        case .claudeCode:
            return Self(patterns: [
                longThreadWarning,
                AgentContextPressurePattern(
                    signal: .contextLow,
                    markers: [
                        "context window is almost full",
                        "context window nearly full",
                        "context is almost full",
                        "context is nearly full",
                        "context low (",
                        "context low:",
                        "context low -",
                        "context low —",
                        "autocompact will trigger soon",
                        "autocompact is disabled. use /compact to free space",
                        "without autocompact, you will hit context limits",
                        "autocompact is thrashing",
                    ],
                    eventThreshold: 1,
                    lowContextPercentageThreshold: 20,
                    lowContextPercentagePhrases: [
                        "until auto-compact",
                        "context left until auto-compact",
                        "context remaining until auto-compact",
                        "context left",
                        "context remaining",
                    ]
                ),
                AgentContextPressurePattern(
                    signal: .repeatedAutoCompaction,
                    markers: [
                        "auto-compacting",
                        "auto compacting",
                        "automatically compacting",
                        "compacting conversation",
                    ],
                    eventThreshold: 2
                ),
            ])
        case .codex:
            return Self(patterns: [
                longThreadWarning,
                AgentContextPressurePattern(
                    signal: .contextLow,
                    markers: [
                        "context window is almost full",
                        "context window nearly full",
                        "context is almost full",
                        "context is nearly full",
                        "context low (",
                        "context low:",
                        "context low -",
                        "context low —",
                    ],
                    eventThreshold: 1,
                    lowContextPercentageThreshold: 20,
                    lowContextPercentagePhrases: [
                        "context left until auto-compact",
                        "context remaining until auto-compact",
                        "context left",
                        "context remaining",
                    ]
                ),
                AgentContextPressurePattern(
                    signal: .repeatedAutoCompaction,
                    markers: [
                        "auto-compacting",
                        "auto compacting",
                        "compacting context",
                        "compacting conversation",
                    ],
                    eventThreshold: 2
                ),
            ])
        }
    }
}
