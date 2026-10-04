import Foundation

/// After an update: hand a running acpmux daemon of another build off to the
/// bundled build (plans/cmux-next/durable-sessions.md section 3).
nonisolated enum AcpmuxVersionHandoff {
    enum Decision: Equatable, Sendable {
        case keep(String)
        case restart
    }

    static func build(fromVersion version: String) -> String? { nil }

    static func decide(_ running: String?, _ bundled: String?, _ agentHosts: Bool) -> Decision {
        .keep("not implemented")
    }
}
