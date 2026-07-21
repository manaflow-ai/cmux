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
            childCount: 500,
            childCountIsCapped: true,
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
        #expect(json["created_total"] as? Int == 1)
        #expect(json["attached_total"] as? Int == 0)
        #expect(json["referenced_total"] as? Int == 7)
        #expect(json["next_cursor"] as? String == "cursor")
        let created = try #require(json["created"] as? [[String: Any]])
        #expect(created.first?["child_count"] as? Int == 500)
        #expect(created.first?["child_count_is_capped"] as? Bool == true)
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
        #expect(item.childCount == nil)
        #expect(!item.childCountIsCapped)
        #expect(item.provenance == .referenced)

        let scanData = Data(#"{"artifacts":[]}"#.utf8)
        let scan = try coding.decode(TerminalArtifactScanResponse.self, from: scanData)
        #expect(scan.sessionID == nil)
        #expect(scan.sessionArtifactTotal == nil)
        #expect(scan.artifacts.isEmpty)
    }

    @Test("directory rows and child counts require folder capability")
    func directoryRowsAreCapabilityGated() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-gallery-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        let nested = folder.appendingPathComponent("nested", isDirectory: true)
        let file = root.appendingPathComponent("notes.txt")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(
            atPath: folder.appendingPathComponent("child.txt").path,
            contents: Data()
        ))
        #expect(FileManager.default.createFile(atPath: file.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: root) }

        let references = [
            ChatArtifactIndexedReference(
                path: folder.path,
                provenance: .referenced,
                lastReferencedSeq: 2
            ),
            ChatArtifactIndexedReference(
                path: file.path,
                provenance: .referenced,
                lastReferencedSeq: 1
            ),
        ]
        let builder = ChatArtifactGalleryBuilder()
        let legacy = builder.page(
            sessionID: "session",
            items: references,
            generation: "generation",
            cursor: nil,
            pageSize: 10,
            query: nil
        )
        #expect(legacy.referenced.map(\.path) == [file.path])
        #expect(legacy.referencedTotal == 2)

        let folders = builder.page(
            sessionID: "session",
            items: references,
            generation: "generation",
            cursor: nil,
            pageSize: 10,
            query: nil,
            includeDirectories: true
        )
        #expect(folders.referenced.map(\.path) == [folder.path, file.path])
        let folderItem = try #require(folders.referenced.first)
        #expect(folderItem.kind == .directory)
        #expect(folderItem.childCount == 2)
        #expect(!folderItem.childCountIsCapped)

        let oldHostPage = ChatArtifactGalleryPage(
            sessionID: "session",
            created: [folderItem],
            referenced: [folderItem],
            referencedTotal: 1
        ).excludingDirectories()
        #expect(oldHostPage.created.isEmpty)
        #expect(oldHostPage.referenced.isEmpty)
        #expect(oldHostPage.referencedTotal == 0)
    }

    @Test("pages fill sections sequentially so loads only extend the list bottom")
    func allSectionsPageLazily() throws {
        let items = (1...3).flatMap { index in
            [
                ChatArtifactIndexedReference(
                    path: "/missing/created-\(index).txt",
                    provenance: .created,
                    lastReferencedSeq: index
                ),
                ChatArtifactIndexedReference(
                    path: "/missing/attached-\(index).txt",
                    provenance: .attached,
                    lastReferencedSeq: index
                ),
                ChatArtifactIndexedReference(
                    path: "/missing/referenced-\(index).txt",
                    provenance: .referenced,
                    lastReferencedSeq: index
                ),
            ]
        }
        let builder = ChatArtifactGalleryBuilder()

        let first = builder.page(
            sessionID: "session",
            items: items,
            generation: "generation",
            cursor: nil,
            pageSize: 2,
            query: nil,
            includeDirectories: true
        )
        let cursor = try #require(first.nextCursor.flatMap(ChatArtifactGalleryCursor.init(token:)))
        let second = builder.page(
            sessionID: "session",
            items: items,
            generation: "generation",
            cursor: cursor,
            pageSize: 2,
            query: nil,
            includeDirectories: true
        )
        let snapshot = ChatArtifactGallerySnapshot(page: first).appending(second)

        // Sequential fill: the first page is created rows only, and every
        // later page extends the grouped list strictly at its bottom, so a
        // scroll-triggered load never inserts rows into an earlier group.
        #expect(first.created.count == 2)
        #expect(first.attached.isEmpty)
        #expect(first.referenced.isEmpty)
        #expect(first.createdTotal == 3)
        #expect(first.attachedTotal == 3)
        #expect(first.referencedTotal == 3)
        #expect(second.created.count == 1)
        #expect(second.attached.count == 1)
        #expect(second.referenced.isEmpty)

        var accumulated = snapshot
        var nextToken = second.nextCursor
        var guardCounter = 0
        while let token = nextToken, guardCounter < 8 {
            let cursor = try #require(ChatArtifactGalleryCursor(token: token))
            let page = builder.page(
                sessionID: "session",
                items: items,
                generation: "generation",
                cursor: cursor,
                pageSize: 2,
                query: nil,
                includeDirectories: true
            )
            if !accumulated.attached.isEmpty {
                #expect(page.created.isEmpty)
            }
            if !accumulated.referenced.isEmpty {
                #expect(page.created.isEmpty)
                #expect(page.attached.isEmpty)
            }
            accumulated = accumulated.appending(page)
            nextToken = page.nextCursor
            guardCounter += 1
        }

        #expect(nextToken == nil)
        #expect(accumulated.created.count == 3)
        #expect(accumulated.attached.count == 3)
        #expect(accumulated.referenced.count == 3)
    }

    @Test("a cursor from another generation requests a fresh paging restart")
    func staleGenerationCursor() throws {
        let staleCursor = ChatArtifactGalleryCursor(
            generation: "old",
            seq: 10,
            path: "/old"
        )

        let page = ChatArtifactGalleryBuilder().page(
            sessionID: "session",
            items: [ChatArtifactIndexedReference(
                path: "/new",
                provenance: .referenced,
                lastReferencedSeq: 20
            )],
            generation: "new",
            cursor: staleCursor,
            pageSize: 10,
            query: nil
        )

        #expect(page.requiresPagingRestart)
        #expect(page.generation == "new")
        #expect(page.created.isEmpty)
        #expect(page.attached.isEmpty)
        #expect(page.referenced.isEmpty)
        #expect(page.nextCursor == nil)
    }

    @Test("directory child counts stop at the listing cap")
    func directoryChildCountCap() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-gallery-cap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0...ArtifactByteReader.maximumDirectoryEntryCount {
            #expect(FileManager.default.createFile(
                atPath: root.appendingPathComponent("item-\(index)").path,
                contents: Data()
            ))
        }

        let page = ChatArtifactGalleryBuilder().page(
            sessionID: "session",
            items: [ChatArtifactIndexedReference(
                path: root.path,
                provenance: .referenced,
                lastReferencedSeq: 1
            )],
            generation: "generation",
            cursor: nil,
            pageSize: 10,
            query: nil,
            includeDirectories: true
        )
        let folder = try #require(page.referenced.first)
        #expect(folder.childCount == ArtifactByteReader.maximumDirectoryEntryCount)
        #expect(folder.childCountIsCapped)
    }

    @Test("count-only scan matches every Session section without stat filtering")
    func sessionCountScan() throws {
        let records = [
            ChatArtifactIndexedReference(
                path: "/definitely-missing/created.swift",
                provenance: .created,
                lastReferencedSeq: 3
            ),
            ChatArtifactIndexedReference(
                path: "/definitely-missing/attachment.png",
                provenance: .attached,
                lastReferencedSeq: 2
            ),
            ChatArtifactIndexedReference(
                path: "/definitely-missing/reference.md",
                provenance: .referenced,
                lastReferencedSeq: 1
            ),
        ]

        let response = TerminalArtifactScanResponse.sessionCount(
            sessionID: "session-1",
            sessionArtifacts: records
        )

        #expect(response.artifacts.isEmpty)
        #expect(response.sessionID == "session-1")
        #expect(response.sessionArtifactTotal == 3)
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
        let shared = try #require(records.first { $0.path == "/private/tmp/shared.txt" })
        #expect(shared.provenance == .created)
        #expect(shared.lastReferencedSeq == 40)
        #expect(records.count == 2)
    }

    @Test("relative paths resolve lexically against the session working directory")
    func relativePathResolution() {
        let timestamp = Date(timeIntervalSince1970: 0)
        let messages = [
            ChatMessage(
                id: "write",
                seq: 1,
                role: .agent,
                timestamp: timestamp,
                kind: .fileEdit(ChatFileEdit(filePath: "notes.md", operation: .write))
            ),
            ChatMessage(
                id: "parent",
                seq: 2,
                role: .agent,
                timestamp: timestamp,
                kind: .toolUse(ChatToolUse(
                    toolName: "Read",
                    summary: "read",
                    referencedPaths: ["../shared/image.png"]
                ))
            ),
        ]
        let records = ChatArtifactIndexedReference.derive(
            from: messages,
            workingDirectory: "/Users/example/project/Sources"
        )
        #expect(Set(records.map(\.path)) == [
            "/Users/example/project/Sources/notes.md",
            "/Users/example/project/shared/image.png",
        ])
    }

    @Test("tmp aliases deduplicate on the canonical macOS spelling")
    func tmpAliasDeduplication() throws {
        let timestamp = Date(timeIntervalSince1970: 0)
        let messages = [
            ChatMessage(
                id: "short-alias",
                seq: 1,
                role: .agent,
                timestamp: timestamp,
                kind: .toolUse(ChatToolUse(
                    toolName: "Read",
                    summary: "read",
                    referencedPaths: ["/tmp/report.png"]
                ))
            ),
            ChatMessage(
                id: "resolved-alias",
                seq: 2,
                role: .agent,
                timestamp: timestamp,
                kind: .fileEdit(ChatFileEdit(
                    filePath: "/private/tmp/report.png",
                    operation: .edit
                ))
            ),
        ]
        let records = ChatArtifactIndexedReference.derive(from: messages)
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.path == "/private/tmp/report.png")
        #expect(record.provenance == .created)
        #expect(record.lastReferencedSeq == 2)
    }

    @Test("apply_patch tool references carry Created provenance")
    func applyPatchProvenance() throws {
        let message = ChatMessage(
            id: "patch",
            seq: 1,
            role: .agent,
            timestamp: Date(timeIntervalSince1970: 0),
            kind: .toolUse(ChatToolUse(
                toolName: "functions.apply_patch",
                summary: "patch",
                referencedPaths: ["Sources/App.swift"]
            ))
        )
        let record = try #require(ChatArtifactIndexedReference.derive(
            from: [message],
            workingDirectory: "/repo"
        ).first)
        #expect(record.path == "/repo/Sources/App.swift")
        #expect(record.provenance == .created)
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

    @Test("mostly-referenced galleries page through three cursor round trips")
    func referencedPagination() throws {
        let ordering = ChatArtifactGalleryOrdering()
        let items = (1...8).map { index in
            ChatArtifactIndexedReference(
                path: "/tmp/page-\(index).txt",
                provenance: index == 8 ? .created : .referenced,
                lastReferencedSeq: index
            )
        }
        var remaining = ordering.items(items, strictlyAfter: nil)
        var paths: [String] = []
        var pages = 0
        while !remaining.isEmpty {
            let page = Array(remaining.prefix(3))
            paths.append(contentsOf: page.map(\.path))
            pages += 1
            guard let last = page.last else { break }
            let token = try ChatArtifactGalleryCursor(
                generation: "fixture",
                seq: last.lastReferencedSeq,
                path: last.path
            ).token()
            remaining = ordering.items(
                items,
                strictlyAfter: ChatArtifactGalleryCursor(token: token)
            )
        }
        #expect(pages == 3)
        #expect(paths == (1...8).reversed().map { "/tmp/page-\($0).txt" })
    }
}
