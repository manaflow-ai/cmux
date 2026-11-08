#if os(iOS) && DEBUG
import CMUXMobileCore
import CmuxAgentChat
import CmuxMobileRPC
import CmuxMobileShell
import Foundation
import SwiftUI

/// Runs the real sheet's loading lifecycle against an in-memory RPC transport.
/// All sample data and transport scaffolding stay in this debug-only facility.
struct TerminalArtifactFilesPreview: View {
    @State private var client: MobileCoreRPCClient?
    @State private var failure: String?

    var body: some View {
        Group {
            if let client {
                TerminalArtifactFilesSheet(
                    workspaceID: "files-preview", surfaceID: "files-preview",
                    source: MobileChatEventSource(
                        client: client, supportsArtifacts: true, supportsArtifactGallery: true
                    ),
                    refreshSignal: .initial, loader: .unsupported()
                )
            } else if let failure {
                Text(failure)
            } else {
                ProgressView()
            }
        }
        .task {
            do {
                let route = try CmxAttachRoute(
                    id: "preview", kind: .iroh,
                    endpoint: .peer(
                        identity: CmxIrohPeerIdentity(endpointID: String(repeating: "a", count: 64)),
                        pathHints: []
                    )
                )
                let ticket = try CmxAttachTicket(
                    workspaceID: "files-preview", terminalID: "files-preview",
                    macDeviceID: "preview", macDisplayName: "Preview", routes: [route],
                    expiresAt: Date().addingTimeInterval(3600)
                )
                client = MobileCoreRPCClient(runtime: FilesPreviewRuntime(), route: route, ticket: ticket)
            } catch {
                failure = String(describing: error)
            }
        }
        .onDisappear {
            if let client {
                Task { await client.disconnect() }
            }
            client = nil
        }
    }
}

private struct FilesPreviewRuntime: MobileSyncRuntime {
    let transportFactory: any CmxByteTransportFactory = FilesPreviewTransportFactory()
    let stackAccessTokenProvider: @Sendable () async throws -> String = { "preview" }
    let stackAccessTokenForceRefresher: @Sendable () async throws -> String = { "preview" }
    let rpcRequestTimeoutNanoseconds: UInt64 = 5_000_000_000
    let pairingRequestTimeoutNanoseconds: UInt64 = 5_000_000_000
    let now: @Sendable () -> Date = Date.init
    let supportedRouteKinds: [CmxAttachTransportKind] = [.iroh]
    let supportsServerPushEvents = false
}

private struct FilesPreviewTransportFactory: CmxByteTransportFactory {
    func makeTransport(for _: CmxAttachRoute) throws -> any CmxByteTransport {
        FilesPreviewTransport()
    }
}

private actor FilesPreviewTransport: CmxByteTransport {
    private var frames: [Data] = []
    private var waiters: [CheckedContinuation<Data?, Never>] = []
    private var closed = false

    func connect() async throws {}

    func receive() async throws -> Data? {
        if !frames.isEmpty { return frames.removeFirst() }
        if closed { return nil }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func send(_ data: Data) async throws {
        var buffer = data
        for payload in try MobileSyncFrameCodec.decodeFrames(from: &buffer) {
            guard let request = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let id = request["id"] as? String else {
                throw CocoaError(.coderReadCorrupt)
            }
            let resultData: Data
            switch request["method"] as? String {
            case "mobile.terminal.artifact.scan":
                resultData = try ChatWireCoding().encode(TerminalArtifactScanResponse(
                    artifacts: [], sessionID: "files-preview"
                ))
            case "mobile.chat.artifact.gallery":
                resultData = try ChatWireCoding().encode(ChatArtifactGalleryPage(
                    sessionID: "files-preview",
                    referenced: [ChatArtifactGalleryItem(
                        path: "/tmp/notes.txt", kind: .text, displayName: "notes.txt", size: 512
                    )],
                    referencedTotal: 1
                ))
            default:
                throw CocoaError(.featureUnsupported)
            }
            let response = try JSONSerialization.data(withJSONObject: [
                "id": id, "ok": true,
                "result": JSONSerialization.jsonObject(with: resultData),
            ])
            let frame = try MobileSyncFrameCodec.encodeFrame(response)
            if waiters.isEmpty {
                frames.append(frame)
            } else {
                waiters.removeFirst().resume(returning: frame)
            }
        }
    }

    func close() async {
        closed = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: nil) }
    }
}
#endif
