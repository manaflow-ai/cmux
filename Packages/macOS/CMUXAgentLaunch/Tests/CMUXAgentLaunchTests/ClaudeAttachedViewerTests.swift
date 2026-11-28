import Darwin
import Foundation
import Testing
@testable import CMUXAgentLaunch

@Test func viewerLeaseRejectsWrongWorkerSocketAndRecycledGeneration() throws {
    let identity = try #require(ClaudeViewerProcessIdentity(pid: Int(getpid())))
    let lease = ClaudeAttachedViewer(
        attachmentID: UUID().uuidString, worker: identity, viewer: identity,
        socketPath: "/test/cmux.sock", workspaceID: UUID().uuidString, surfaceID: UUID().uuidString
    )
    #expect(lease.admits(workerPID: Int(getpid()), socketPath: "/test/cmux.sock"))
    #expect(!lease.admits(workerPID: Int(getpid()) + 1, socketPath: "/test/cmux.sock"))
    #expect(!lease.admits(workerPID: Int(getpid()), socketPath: "/other/cmux.sock"))
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(lease)) as? [String: Any])
    var viewer = try #require(object["viewer"] as? [String: Any])
    viewer["seconds"] = 1
    object["viewer"] = viewer
    let recycled = try JSONDecoder().decode(ClaudeAttachedViewer.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(!recycled.admits(workerPID: Int(getpid()), socketPath: "/test/cmux.sock"))
}

@Test func closingOldViewerPreservesNewViewerAndRejectsForeignSocket() throws {
    let identity = try #require(ClaudeViewerProcessIdentity(pid: Int(getpid())))
    let a = ClaudeAttachedViewer(attachmentID: UUID().uuidString, worker: identity, viewer: identity,
        socketPath: "/test", workspaceID: UUID().uuidString, surfaceID: UUID().uuidString, attachedAt: 1)
    let b = ClaudeAttachedViewer(attachmentID: UUID().uuidString, worker: identity, viewer: identity,
        socketPath: "/test", workspaceID: UUID().uuidString, surfaceID: UUID().uuidString, attachedAt: 2)
    let both = ClaudeViewerSubscriptions().adding(a).adding(b)
    #expect(both.candidates(workerPID: identity.pid, socketPath: "/test") == [b, a])
    #expect(both.removing(attachmentID: a.attachmentID, viewerPID: identity.pid, socketPath: "/test").viewers == [b])
    #expect(both.removing(attachmentID: a.attachmentID, viewerPID: identity.pid, socketPath: "/other").viewers == [a, b])
}
