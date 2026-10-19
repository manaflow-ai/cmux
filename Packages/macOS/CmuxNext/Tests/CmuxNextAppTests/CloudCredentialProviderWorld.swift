import CmuxNextDaemon
import Foundation
@testable import CmuxNextApp

@MainActor
final class CloudCredentialProviderWorld {
    enum Failure: Error { case unsupported }
    let started = AsyncStream<Int>.makeStream()
    var holdPosts = false
    var refuseInvalidation = false
    private(set) var registrations = 0
    private(set) var invalidations = 0
    private(set) var postCount = 0
    private var pending: [Int: CheckedContinuation<Void, Never>] = [:]

    func register(_ request: AppsProviderRegisterRequest) -> JSONValue {
        registrations += 1
        return .object(["families": .array(request.families.map(JSONValue.string))])
    }
    func invalidate(_: AppsProviderScopeChangedRequest) throws -> JSONValue {
        invalidations += 1
        if refuseInvalidation { throw Failure.unsupported }
        return .object(["servers": .number(0)])
    }
    func release(_ post: Int) { pending.removeValue(forKey: post)?.resume() }

    func provider() -> CloudCredentialProvider {
        CloudCredentialProvider(relay: CloudCredentialRelay(
            post: { [self] _, _, _ in await self.post() }, token: { "install-token-for-test" }, invalidate: {},
            session: { .init(signedIn: true, team: "team_test") }, allowedOps: { ["cloud.machine.list"] }))
    }
    private func post() async -> (status: Int, body: Data) {
        postCount += 1
        let index = postCount
        if holdPosts {
            await withCheckedContinuation { pending[index] = $0; started.continuation.yield(index) }
        }
        return (200, Data(#"{"op":"cloud.machine.list","value":{"machines":[]},"revision":"1","stream":"s"}"#.utf8))
    }
}
