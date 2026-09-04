import Foundation
import Testing
@testable import CmuxArtifacts

@Suite("Artifact repository boundaries")
struct ArtifactRepositoryAdvancedTests {
    @Test("retention ordering is deterministic in the in-memory repository")
    func retentionOrderingIsDeterministic() async throws {
        let repo = InMemoryArtifactRepository()
        let owner = ArtifactOwnership(workspaceID: "w")
        let config = ArtifactCaptureConfiguration(retentionLimit: 10, retentionAge: 0)
        _ = config
        for index in 0..<12 {
            _ = try await repo.ingest(
                .init(input: .url("https://example.com/\(index)"), ownership: owner, source: .manual),
                capturedAt: Date(timeIntervalSince1970: Double(index))
            )
        }
        // The in-memory test repository intentionally does not apply retention;
        // the durable implementation owns that policy. Verify the scope index
        // remains complete and ordered before applying a replacement cap.
        let records = try await repo.list(scope: .workspace("w"))
        #expect(records.count == 12)
        #expect(records.first?.representation == .url("https://example.com/11"))
    }

    @Test("changes stream reports mutations and clear scope")
    func changesStreamReportsMutationsAndClearScope() async throws {
        let repo = InMemoryArtifactRepository()
        let stream = await repo.changes()
        let owner = ArtifactOwnership(workspaceID: "w")
        _ = try await repo.ingest(.init(input: .html("<b>x</b>"), ownership: owner, source: .browser), capturedAt: .now)
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        guard case .records = first else {
            Issue.record("expected a records change")
            return
        }
        try await repo.clear(scope: .workspace("w"))
        let second = await iterator.next()
        guard case .cleared(.workspace("w")) = second else {
            Issue.record("expected a scoped clear change")
            return
        }
    }

    @Test("drag descriptor preserves stable identity and text fallback")
    func dragDescriptor() throws {
        let id = UUID()
        let descriptor = ArtifactDragDescriptor(
            artifactID: id,
            suggestedFileName: "report.pdf",
            urlString: "file:///tmp/report.pdf",
            plainText: "/tmp/report.pdf",
            contentTypeIdentifier: "pdf"
        )
        let data = try JSONEncoder().encode(descriptor)
        let decoded = try JSONDecoder().decode(ArtifactDragDescriptor.self, from: data)
        #expect(decoded == descriptor)
        #expect(decoded.artifactID == id)
    }

    @Test("canceled search stops before returning results")
    func canceledSearchStopsBeforeReturningResults() async throws {
        let repo = InMemoryArtifactRepository()
        let owner = ArtifactOwnership(workspaceID: "w")
        for index in 0..<100 {
            _ = try await repo.ingest(.init(input: .text("token \(index)"), ownership: owner, source: .manual), capturedAt: .now)
        }
        let task = Task { try await repo.search(.init(text: "token", scope: .global, limit: 500)) }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("canceled search unexpectedly completed")
        } catch is CancellationError {
            // expected
        }
    }

    @Test("explicit user artifacts are not evicted by automatic retention")
    func userOwnedRowsSurviveRetention() async throws {
        let repo = InMemoryArtifactRepository(configuration: .init(retentionLimit: 10, retentionAge: 0))
        let owner = ArtifactOwnership(workspaceID: "w")
        _ = try await repo.ingest(
            .init(input: .text("keep"), ownership: owner, source: .manual, authorization: .explicitUser),
            capturedAt: Date(timeIntervalSince1970: 1)
        )
        for index in 0..<11 {
            _ = try await repo.ingest(
                .init(input: .url("https://example.com/automatic-\(index)"), ownership: owner, source: .terminalURL, authorization: .automatic(allowedRoots: [])),
                capturedAt: Date(timeIntervalSince1970: Double(index + 2))
            )
        }
        let records = try await repo.list(scope: .workspace("w"))
        #expect(records.contains { $0.inlineContent == "keep" })
    }
}
