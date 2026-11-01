import Foundation
import CmuxNextCompat
import Testing
@testable import CmuxNextAgentPane

/// A chat on the person's own Cloud VM: the wire's `initialize` names `ownerCloud` only while the
/// link's Cloud API owner answer holds, so the page lets a Codex or opencode chat send there and
/// nowhere else (Leo, 2026-10-30: "we should just have it"). Every answer stays `origin: "remote"`.
@Suite
struct RemoteAcpmuxOwnerCloudTests {
    /// The wire's first `initialize` answer, as the page reads it.
    private func initialized(_ wire: RemoteAcpmuxWire) async throws -> [String: Any] {
        let text: String = await withCheckedContinuation { done in
            let once = Mutex(false)
            Task {
                try await wire.open(onFrame: { frame in
                    guard frame.contains("\"protocolVersion\""), once.withLock({ was in defer { was = true }; return !was }) else { return }
                    done.resume(returning: frame)
                }, onClose: { _, _ in })
                wire.send(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#) { _ in }
            }
        }
        let reply = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let result = try #require(reply["result"] as? [String: Any])
        let meta = try #require(result["_meta"] as? [String: Any])
        return try #require(meta["acpmux"] as? [String: Any])
    }

    @Test func onlyTheOwnersCloudVmIsNamedOwnerCloud() async throws {
        let client = RemoteAcpmuxWireAnswerTests.DaemonClient()
        let owned = try await initialized(RemoteAcpmuxWire(client: client, session: "s", ownerCloud: { true }))
        #expect(owned["origin"] as? String == "remote")
        #expect(owned["ownerCloud"] as? Bool == true)

        // The link's owner answer is gone (another link, a teammate's machine): not named.
        let lost = try await initialized(RemoteAcpmuxWire(client: client, session: "s", ownerCloud: { false }))
        #expect(lost["origin"] as? String == "remote")
        #expect(lost["ownerCloud"] == nil)

        // A machine that is not a Cloud one (a Mac, an SSH host): never named.
        let plain = try await initialized(RemoteAcpmuxWire(client: client, session: "s"))
        #expect(plain["origin"] as? String == "remote")
        #expect(plain["ownerCloud"] == nil)

        // A new chat's wire, before its first send, takes the same answer.
        let start: RemoteAcpmuxWire.Start = { _, _, _ in throw CancellationError() }
        let fresh = try await initialized(RemoteAcpmuxWire(start: start, ownerCloud: { true }))
        #expect(fresh["ownerCloud"] as? Bool == true)
    }

    /// The link's owner answer decides, and only through a daemon that serves the owner start.
    @Test func theCapabilityIsTheCloudDaemonsName() {
        #expect(RemoteAcpmuxWire.ownerCloudCapability == "agent-session-start-owner-cloud-v1")
    }

    @Test func theOwnerAnswerAndTheDaemonDecide() async throws {
        // Built outside the macros: #require's expansion passes its call's arguments on without
        // the parameter's @Sendable.
        let ownerLink: @Sendable () async -> Int? = { 7 }
        let noOwnerLink: @Sendable () async -> Int? = { nil }
        let noLink = RemoteAcpmuxWire.ownerCloud(nil, served: true)
        let unserved = RemoteAcpmuxWire.ownerCloud(ownerLink, served: false)
        #expect(noLink == nil)
        #expect(unserved == nil)
        let ownedAnswer = RemoteAcpmuxWire.ownerCloud(ownerLink, served: true)
        let owned = try #require(ownedAnswer)
        #expect(await owned())
        let lostAnswer = RemoteAcpmuxWire.ownerCloud(noOwnerLink, served: true)
        let lost = try #require(lostAnswer)
        #expect(await lost() == false)
    }
}
