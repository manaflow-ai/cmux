import CmuxConversation
@testable import CmuxConversationUI
import CryptoKit
import Foundation
import XCTest

@MainActor
final class ConversationArtifactTests: XCTestCase {
    func testMultiChunkTransferPinsFirstChunkHashAndSanitizesName() async throws {
        let data = Data("hello from a bounded transfer".utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let client = ArtifactTestClient(data: data, sha256: hash, fileName: "../../private.txt")
        let model = ConversationModel(client: client, scopeID: "artifact-host")
        model.selectSession(id: ArtifactTestClient.sessionID)
        try await waitUntilConnected(model)

        let artifact = ConversationArtifact(artifactID: "artifact-1", fileName: "../../private.txt", mediaType: "text/plain", byteCount: Int64(data.count), sha256: nil)
        let url = try await model.downloadArtifact(artifact)

        XCTAssertEqual(url.lastPathComponent, "private.txt")
        XCTAssertFalse(url.path.contains("/private.txt/"))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testHashMismatchFailsBeforeWriting() async throws {
        let data = Data("correct bytes".utf8)
        let wrongHash = String(repeating: "0", count: 64)
        let client = ArtifactTestClient(data: data, sha256: wrongHash, fileName: "artifact.txt")
        let model = ConversationModel(client: client, scopeID: "artifact-host")
        model.selectSession(id: ArtifactTestClient.sessionID)
        try await waitUntilConnected(model)

        let artifact = ConversationArtifact(artifactID: "artifact-1", fileName: "artifact.txt", mediaType: "text/plain", byteCount: Int64(data.count), sha256: nil)
        do {
            _ = try await model.downloadArtifact(artifact)
            XCTFail("A mismatched pinned hash must fail")
        } catch ConversationArtifactError.hashMismatch {
            // Expected.
        }
    }

    func testChunkHashChangeFails() async throws {
        let data = Data("changing hash".utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let client = ArtifactTestClient(data: data, sha256: hash, fileName: "artifact.txt", changesHashAfterFirstChunk: true)
        let model = ConversationModel(client: client, scopeID: "artifact-host")
        model.selectSession(id: ArtifactTestClient.sessionID)
        try await waitUntilConnected(model)

        let artifact = ConversationArtifact(artifactID: "artifact-1", fileName: "artifact.txt", mediaType: "text/plain", byteCount: Int64(data.count), sha256: nil)
        do {
            _ = try await model.downloadArtifact(artifact)
            XCTFail("Every chunk must retain the pinned hash")
        } catch ConversationArtifactError.invalidChunk {
            // Expected.
        }
    }

    private func waitUntilConnected(_ model: ConversationModel) async throws {
        for _ in 0..<50 {
            if model.connectionState == .connected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Fixture client did not connect")
    }
}

private actor ArtifactTestClient: ConversationArtifactClient {
    static let sessionID = ConversationID(rawValue: "artifact-session")
    private let data: Data
    private let sha256: String
    private let fileName: String
    private let changesHashAfterFirstChunk: Bool
    private var calls = 0

    init(data: Data, sha256: String, fileName: String, changesHashAfterFirstChunk: Bool = false) {
        self.data = data
        self.sha256 = sha256
        self.fileName = fileName
        self.changesHashAfterFirstChunk = changesHashAfterFirstChunk
    }

    nonisolated func listSessions() async throws -> [ConversationSession] {
        [ConversationSession(id: Self.sessionID, provider: .codex, title: "Artifact test", workspaceID: "artifact", directory: "/tmp", state: .ready)]
    }

    nonisolated func createSession(_ request: ConversationCreateRequest) async throws -> ConversationSession {
        ConversationSession(id: Self.sessionID, provider: request.provider, title: "Artifact test", workspaceID: request.workspaceID, directory: request.directory, state: .ready)
    }

    nonisolated func snapshot(sessionID: ConversationID) async throws -> ConversationSnapshot {
        let session = ConversationSession(id: Self.sessionID, provider: .codex, title: "Artifact test", workspaceID: "artifact", directory: "/tmp", state: .ready)
        return ConversationSnapshot(session: session, cursor: 0, generation: session.generation, capabilities: ConversationCapabilities(protocolVersion: "test/1", supportsResume: true))
    }

    nonisolated func replay(sessionID: ConversationID, after: ConversationCursor) async throws -> [ConversationEvent] { [] }

    nonisolated func events(sessionID: ConversationID, after: ConversationCursor) async -> AsyncThrowingStream<ConversationEvent, any Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }

    nonisolated func execute(_ command: ConversationCommandEnvelope) async throws -> ConversationReceipt {
        ConversationReceipt(id: command.commandID, sessionID: command.sessionID, state: .applied, generation: "test")
    }

    nonisolated func receipt(_ query: ConversationReceiptQuery) async throws -> ConversationReceipt? { nil }

    nonisolated func receipt(sessionID: ConversationID, commandID: ConversationCommandID) async throws -> ConversationReceipt? { nil }

    func artifactChunk(_ query: ConversationArtifactQuery) async throws -> ConversationArtifactChunk {
        let chunkSize = max(1, data.count / 2)
        let offset = Int(query.offset)
        let end = min(data.count, offset + chunkSize)
        calls += 1
        let chunkData = offset < data.count ? data.subdata(in: offset..<end) : Data()
        let hash = changesHashAfterFirstChunk && calls > 1 ? String(repeating: "f", count: 64) : sha256
        return ConversationArtifactChunk(artifactID: query.artifactID, fileName: fileName, offset: query.offset, totalBytes: UInt64(data.count), sha256: hash, data: chunkData)
    }
}
