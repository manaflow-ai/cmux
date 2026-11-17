import AppKit
import CmuxHomeCore
@testable import CmuxNextHome
import CmuxNextPages
import CmuxNextSettings
import Foundation
import MessagesLabHome
import Testing

/// The Messages page's drag of an attachment out of the transcript: the host starts a native drag of
/// a file promise while the button is held, and the drop fetches the original where it appears.
@MainActor
struct HomePageAttachmentDragTests {
    /// The fetches the drop asked for.
    @MainActor final class Asked {
        var calls: [(AttachmentRef, AttachmentLocation)] = []
    }

    private static let params: JSONValue = .object([
        "conversation": "c1", "message": "m7", "partIndex": .number(2),
        "attachment": .object(["hash": "h1", "name": "notes.pdf", "mimeType": "application/pdf", "byteCount": .number(2048)]),
    ])

    @Test func aHeldDragStartsAFilePromiseThatFetchesTheOriginalWhereItAppears() async throws {
        let asked = Asked()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("drag-\(UUID().uuidString).pdf")
        try Data("pdf".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let drag = HomePageAttachmentDrag(window: { nil }, personOnly: "no") { ref, place in
            asked.calls.append((ref, place))
            return file
        }
        drag.mouseHeld = { true }
        var items: [NSDraggingItem] = []
        drag.begin = { item, _, _ in
            items.append(item)
            return true
        }
        #expect(try drag.call(Self.params, userGesture: true) == .object(["started": .bool(true)]))
        let promise = try #require(items.first?.item as? NSFilePromiseProvider)
        #expect(promise.fileType == "com.adobe.pdf")
        let source = try #require(drag.current)
        #expect(source.name == "notes.pdf")
        // The drop asks for the file: the original is fetched then and written where Finder said.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent(source.filePromiseProvider(promise, fileNameForType: promise.fileType))
        let error: Error? = await withCheckedContinuation { done in
            source.filePromiseProvider(promise, writePromiseTo: target) { done.resume(returning: $0) }
        }
        #expect(error == nil)
        #expect(try Data(contentsOf: target) == Data("pdf".utf8))
        #expect(asked.calls.map(\.0.hash) == ["h1"])
        #expect(asked.calls.first?.1 == AttachmentLocation(conversation: ConversationID("c1"), message: MessageID("m7"), partIndex: 2))
    }

    @Test func aReleasedButtonStartsNothingAndAScriptedOrMalformedCallIsRefused() throws {
        let drag = HomePageAttachmentDrag(window: { nil }, personOnly: "only you") { _, _ in nil }
        var began = 0
        drag.begin = { _, _, _ in
            began += 1
            return true
        }
        drag.mouseHeld = { false }
        #expect(try drag.call(Self.params, userGesture: true) == .object(["started": .bool(false)]))
        drag.mouseHeld = { true }
        #expect(throws: PageError.self) { try drag.call(Self.params, userGesture: false) }
        #expect(throws: PageError.self) { try drag.call(.object(["conversation": "c1", "message": "m7"]), userGesture: true) }
        #expect(throws: PageError.self) {
            try drag.call(.object(["conversation": "c1", "message": "m7", "partIndex": .number(1.5),
                                   "attachment": .object(["hash": "h1", "name": "a"])]), userGesture: true)
        }
        #expect(began == 0)
        #expect(drag.current == nil)
    }

    @Test func noWindowStartsNoDrag() throws {
        let drag = HomePageAttachmentDrag(window: { nil }, personOnly: "no") { _, _ in nil }
        drag.mouseHeld = { true }
        #expect(try drag.call(Self.params, userGesture: true) == .object(["started": .bool(false)]))
        #expect(drag.current == nil)
    }
}
