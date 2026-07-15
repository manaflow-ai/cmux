import CmuxCore
import CmuxRemoteDaemon
import CmuxRemoteSession
import Foundation

/// Records runtime-state publications after callers drain the coordinator queue.
final class RuntimeStateRecordingHost: RemoteSessionHosting, @unchecked Sendable {
    // The coordinator owns at most one publication task. Tests await that task
    // and then drain the coordinator queue before reading this focused fake.
    nonisolated(unsafe) var documents: [RemoteRuntimeStateDocument] = []
    nonisolated(unsafe) var revisions: [UInt64] = []
    let acceptsDocuments: Bool
    let acceptsRevisions: Bool
    let documentGate: RuntimeStatePublicationGate?
    let revisionGate: RuntimeStatePublicationGate?

    init(
        acceptsDocuments: Bool = true,
        acceptsRevisions: Bool = true,
        documentGate: RuntimeStatePublicationGate? = nil,
        revisionGate: RuntimeStatePublicationGate? = nil
    ) {
        self.acceptsDocuments = acceptsDocuments
        self.acceptsRevisions = acceptsRevisions
        self.documentGate = documentGate
        self.revisionGate = revisionGate
    }

    func publishConnectionState(_: WorkspaceRemoteConnectionState, detail _: String?) {}
    func publishDaemonStatus(_: WorkspaceRemoteDaemonStatus) {}
    func publishProxyEndpoint(_: BrowserProxyEndpoint?) {}
    func publishPortsSnapshot(detectedByPanel _: [UUID: [Int]], detected _: [Int]) {}
    func publishHeartbeat(count _: Int, lastSeenAt _: Date?) {}
    func publishBootstrapRemoteTTY(_: String) {}
    func publishRuntimeState(_ document: RemoteRuntimeStateDocument) async -> Bool {
        documents.append(document)
        if let documentGate {
            return await documentGate.waitForRelease()
        }
        return acceptsDocuments
    }

    func publishRuntimeStateRevision(_ revision: UInt64) async -> Bool {
        revisions.append(revision)
        if let revisionGate {
            return await revisionGate.waitForRelease()
        }
        return acceptsRevisions
    }
}

actor RuntimeStatePublicationGate {
    private var hasBlockedPublication = false
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Bool, Never>?

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitForRelease() async -> Bool {
        guard !hasBlockedPublication else { return true }
        hasBlockedPublication = true
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func release(accepted: Bool = true) {
        releaseContinuation?.resume(returning: accepted)
        releaseContinuation = nil
    }
}
