import Foundation

/// How many coding agents the user has open, by provider. Drives the Sleepy
/// Mode pets: one cute pet per running agent, to make running lots of agents
/// feel rewarding.
struct SleepyAgentCounts: Equatable, Sendable {
    var claude = 0
    var codex = 0
    var opencode = 0
    var pi = 0
    var other = 0

    var total: Int { claude + codex + opencode + pi + other }
}
