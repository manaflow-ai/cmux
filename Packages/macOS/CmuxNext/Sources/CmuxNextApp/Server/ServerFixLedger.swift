import CmuxNextServerHelper
import Foundation

/// The app's own record of the fixes the helper applied (not implemented yet).
nonisolated struct ServerFixLedger: Sendable {
    nonisolated enum Contents: Sendable, Equatable {
        case fixes(Set<ServerFix>)
        case unknown

        var toRevert: [ServerFix] { [] }
    }

    let url: URL

    static var standard: ServerFixLedger { ServerFixLedger(url: URL(fileURLWithPath: "/dev/null")) }

    @concurrent func load() async -> Contents { .fixes([]) }
    @concurrent func record(_ fix: ServerFix) async throws {}
    @concurrent func clear(_ fix: ServerFix) async throws {}
    @concurrent func reset() async throws {}
}
