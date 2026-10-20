import CmuxNextDaemon
import CmuxNextPages
import CmuxNextSettings
import Foundation

/// Stub (red commit): the Cloud page's namespace is not served yet.
@MainActor
final class CloudPageProvider: PageProvider {
    static let watchStream = "cmux.cloud.machine.watch"

    init(op: @escaping CloudAppOp, signIn: @escaping @MainActor () async -> Bool = { false },
         signOut: @escaping @MainActor () async -> Void = {}) {}

    var watcherCount: Int { 0 }

    func call(_ name: String, params: CmuxNextSettings.JSONValue, context: PageCallContext) async throws -> CmuxNextSettings.JSONValue {
        throw PageError(code: "cmux.cloud.unsupported", message: name)
    }
}
