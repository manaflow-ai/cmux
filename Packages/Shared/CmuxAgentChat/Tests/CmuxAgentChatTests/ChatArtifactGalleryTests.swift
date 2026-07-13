import Foundation
import Testing
@testable import CmuxAgentChat

@Suite("Chat artifact gallery")
struct ChatArtifactGalleryTests {
    @Test("gallery page and item metadata round-trip with snake-case wire keys")
    func wireRoundTrip() throws {
        let item = ChatArtifactGalleryItem(
            path: "/tmp/Report.PNG",
            kind: .image,
            displayName: "Report.PNG",
            size: 42,
            modifiedAt: Date(timeIntervalSince1970: 123),
            exists: false,
            provenance: .created
        )
        let page = ChatArtifactGalleryPage(
            sessionID: "session-1",
            created: [item],
            referencedTotal: 7,
            nextCursor: "cursor",
            generation: "generation"
        )
        let coding = ChatWireCoding()
        let data = try coding.encode(page)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["session_id"] as? String == "session-1")
        #expect(json["referenced_total"] as? Int == 7)
        #expect(json["next_cursor"] as? String == "cursor")
        #expect(try coding.decode(ChatArtifactGalleryPage.self, from: data) == page)

        let scan = TerminalArtifactScanResponse(artifacts: [], sessionID: "session-1")
        let scanData = try coding.encode(scan)
        #expect(try coding.decode(TerminalArtifactScanResponse.self, from: scanData) == scan)
    }

    @Test("legacy gallery item and terminal scan fields fail open")
    func legacyDecode() throws {
        let coding = ChatWireCoding()
        let itemData = Data(#"{"path":"/tmp/old.txt","kind":"text","display_name":"old.txt"}"#.utf8)
        let item = try coding.decode(ChatArtifactGalleryItem.self, from: itemData)
        #expect(item.exists)
        #expect(item.provenance == .referenced)

        let scanData = Data(#"{"artifacts":[]}"#.utf8)
        let scan = try coding.decode(TerminalArtifactScanResponse.self, from: scanData)
        #expect(scan.sessionID == nil)
        #expect(scan.artifacts.isEmpty)
    }

    @Test("written paths outrank attachments and references while last seq advances")
    func provenancePrecedence() throws {
        let timestamp = Date(timeIntervalSince1970: 0)
        let messages = [
            ChatMessage(
                id: "reference",
                seq: 10,
                role: .agent,
                timestamp: timestamp,
                kind: .toolUse(ChatToolUse(
                    toolName: "Read",
                    summary: "read",
                    status: .succeeded,
                    referencedPaths: ["/tmp/shared.txt", "/tmp/only-reference.txt"]
                ))
            ),
            ChatMessage(
                id: "attachment",
                seq: 20,
                role: .user,
                timestamp: timestamp,
                kind: .attachment(ChatAttachment(
                    media: .file,
                    displayName: "shared.txt",
                    hostPath: "/tmp/shared.txt"
                ))
            ),
            ChatMessage(
                id: "write",
                seq: 30,
                role: .agent,
                timestamp: timestamp,
                kind: .fileEdit(ChatFileEdit(filePath: "/tmp/shared.txt", operation: .write))
            ),
            ChatMessage(
                id: "late-read",
                seq: 40,
                role: .agent,
                timestamp: timestamp,
                kind: .toolUse(ChatToolUse(
                    toolName: "Read",
                    summary: "read again",
                    status: .succeeded,
                    referencedPaths: ["/tmp/shared.txt"]
                ))
            ),
        ]
        let records = ChatArtifactIndexedReference.derive(from: messages)
        let shared = try #require(records.first { $0.path == "/tmp/shared.txt" })
        #expect(shared.provenance == .created)
        #expect(shared.lastReferencedSeq == 40)
        #expect(records.count == 2)
    }

    @Test("cursor remains strictly append-only across generation refresh")
    func cursorStability() throws {
        let ordering = ChatArtifactGalleryOrdering()
        let original = [
            ChatArtifactIndexedReference(path: "/a", provenance: .referenced, lastReferencedSeq: 30),
            ChatArtifactIndexedReference(path: "/b", provenance: .referenced, lastReferencedSeq: 20),
            ChatArtifactIndexedReference(path: "/c", provenance: .referenced, lastReferencedSeq: 10),
        ]
        let first = Array(ordering.items(original, strictlyAfter: nil).prefix(2))
        #expect(first.map(\.path) == ["/a", "/b"])
        let token = try ChatArtifactGalleryCursor(
            generation: "old",
            seq: first[1].lastReferencedSeq,
            path: first[1].path
        ).token()
        let cursor = try #require(ChatArtifactGalleryCursor(token: token))
        let refreshed = original + [
            ChatArtifactIndexedReference(path: "/new", provenance: .referenced, lastReferencedSeq: 100),
            ChatArtifactIndexedReference(path: "/bb", provenance: .referenced, lastReferencedSeq: 20),
        ]
        #expect(ordering.items(refreshed, strictlyAfter: cursor).map(\.path) == ["/bb", "/c"])
    }

    @Test("search matches basename and path case-insensitively")
    func search() {
        let ordering = ChatArtifactGalleryOrdering()
        let items = [
            ChatArtifactIndexedReference(path: "/Users/me/Reports/Final.PNG", provenance: .created, lastReferencedSeq: 2),
            ChatArtifactIndexedReference(path: "/Users/me/notes.txt", provenance: .referenced, lastReferencedSeq: 1),
        ]
        #expect(ordering.search(items, query: "final.png").map(\.path) == [items[0].path])
        #expect(ordering.search(items, query: "REPORTS").map(\.path) == [items[0].path])
    }
}
