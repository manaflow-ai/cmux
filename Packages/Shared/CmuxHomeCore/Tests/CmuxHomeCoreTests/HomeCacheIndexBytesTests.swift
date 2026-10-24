import Foundation
import Testing
@testable import CmuxHomeCore

/// The Home cache index's bytes are a function of its value. `JSONEncoder`'s `.sortedKeys`
/// orders struct fields and `String`-keyed dictionaries only; `ConversationID` is not
/// `CodingKeyRepresentable`, so the drafts, scroll anchors and draft attachments (and inline
/// windows) encoded as `[key, value, ...]` arrays in hash order, and two equal states built in
/// different orders wrote different files. The write test compares values (an equal state writes
/// nothing); this pins the encoding, so a file on disk, a diff of it or a byte compare never
/// sees a change that is not one.
@Suite struct HomeCacheIndexBytesTests {
    static func cache() -> HomeCache {
        HomeCache(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("home-index-bytes-\(UUID().uuidString)/home.json"))
    }

    @Test func equalStatesBuiltInOtherOrdersWriteTheSameIndexBytes() async throws {
        let ids = (0..<64).map { ConversationID("conv_\($0)") }
        var first = HomeCacheState()
        for id in ids {
            first.drafts[id] = "draft \(id.rawValue)"
            first.scroll[id] = HomeScrollAnchor(message: MessageID("\(id.rawValue)-m1"), offset: 3)
        }
        var second = HomeCacheState()
        second.drafts.reserveCapacity(4096)
        second.scroll.reserveCapacity(4096)
        for id in ids.reversed() {
            second.drafts[id] = "draft \(id.rawValue)"
            second.scroll[id] = HomeScrollAnchor(message: MessageID("\(id.rawValue)-m1"), offset: 3)
        }
        #expect(first.drafts == second.drafts && first.scroll == second.scroll)
        // An inbox summary's read cursors are participant-keyed: the same hash-order encoding.
        let readers = (0..<48).map { ParticipantID("user_\($0)") }
        let conversation = ConversationID("conv_read")
        func summary(_ order: [ParticipantID], capacity: Int) -> ConversationSummary {
            var cursors: [ParticipantID: Seq] = [:]
            var times: [ParticipantID: Date] = [:]
            cursors.reserveCapacity(capacity)
            times.reserveCapacity(capacity)
            for (index, reader) in order.enumerated() {
                cursors[reader] = Seq(index % 7)
                times[reader] = Date(timeIntervalSince1970: Double(reader.rawValue.count))
            }
            for reader in order { cursors[reader] = Seq(reader.rawValue.count) }
            return ConversationSummary(id: conversation, participants: [], createdAt: Date(timeIntervalSince1970: 0),
                                       updatedAt: Date(timeIntervalSince1970: 0), readCursors: cursors,
                                       readCursorTimes: times)
        }
        first.conversations[conversation] = summary(readers, capacity: 0)
        second.conversations[conversation] = summary(readers.reversed(), capacity: 2048)
        #expect(first.conversations == second.conversations)

        let one = Self.cache()
        let other = Self.cache()
        #expect(await one.write(first, sequence: 1, writer: UUID()))
        #expect(await other.write(second, sequence: 1, writer: UUID()))
        let bytes = try Data(contentsOf: one.url)
        let otherBytes = try Data(contentsOf: other.url)
        #expect(bytes == otherBytes, "equal states wrote different index bytes")
        // Still the format every build reads: the dictionaries decode back to the same values.
        let loaded = try #require(other.load())
        #expect(loaded.drafts == first.drafts && loaded.scroll == first.scroll)
    }

    @Test func aWholeSnapshotEncodesItsDictionariesInKeyOrder() throws {
        var snapshot = HomeCacheSnapshot()
        let ids = (0..<32).map { ConversationID("conv_\($0)") }
        var reversed = HomeCacheSnapshot()
        reversed.drafts.reserveCapacity(1024)
        for id in ids { snapshot.drafts[id] = id.rawValue }
        for id in ids.reversed() { reversed.drafts[id] = id.rawValue }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(snapshot) == encoder.encode(reversed))
        #expect(try JSONDecoder().decode(HomeCacheSnapshot.self, from: encoder.encode(reversed)) == snapshot)
    }
}
