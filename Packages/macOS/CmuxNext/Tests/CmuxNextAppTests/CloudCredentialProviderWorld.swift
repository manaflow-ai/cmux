import CmuxNextDaemon
import Foundation
@testable import CmuxNextApp

@MainActor
final class CloudCredentialProviderWorld {
    enum Failure: Error { case unsupported }
    let started = AsyncStream<Int>.makeStream()
    let invalidationStarted = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var holdPosts = false
    var refuseInvalidation = false
    var nativeCapability = true
    private(set) var registrations = 0
    private(set) var invalidations = 0
    private(set) var postCount = 0
    private var pending: [Int: CheckedContinuation<Void, Never>] = [:]
    private var heldInvalidation: CheckedContinuation<Void, Never>?

    func register(_ request: AppsProviderRegisterRequest) -> JSONValue {
        registrations += 1
        var result: [String: JSONValue] = ["families": .array(request.families.map(JSONValue.string))]
        if nativeCapability { result["native_link_binding"] = .number(1) }
        return .object(result)
    }
    func invalidate(_: AppsProviderScopeChangedRequest) throws -> JSONValue {
        invalidations += 1
        if refuseInvalidation { throw Failure.unsupported }
        return .object(["servers": .number(0)])
    }
    func release(_ post: Int) { pending.removeValue(forKey: post)?.resume() }

    func holdInvalidation(_ request: AppsProviderScopeChangedRequest) async throws -> JSONValue {
        let result = try invalidate(request)
        await withCheckedContinuation {
            heldInvalidation = $0
            invalidationStarted.continuation.yield(())
        }
        return result
    }

    func releaseInvalidation() {
        heldInvalidation?.resume()
        heldInvalidation = nil
    }

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
