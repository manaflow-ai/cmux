import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("WorkstreamLogBackwardReader")
struct WorkstreamLogBackwardReaderTests {
    @Test("Rows come newest-first with their start offsets at every chunk size", arguments: [1, 2, 3, 7, 64 * 1024])
    func rowsNewestFirst(chunkSize: Int) throws {
        let text = "alpha\nbeta\n\ngamma-delta\n"
        let rows = try Self.rows(of: text, chunkSize: chunkSize)
        #expect(rows.map(\.text) == ["gamma-delta", "beta", "alpha"])
        #expect(rows.map(\.startOffset) == [12, 6, 0])
    }

    @Test("A final row without a newline is returned first")
    func unterminatedFinalRow() throws {
        let rows = try Self.rows(of: "one\ntwo", chunkSize: 3)
        #expect(rows.map(\.text) == ["two", "one"])
        #expect(rows.map(\.startOffset) == [4, 0])
    }

    @Test("Reading stops at the start offset of a cursor")
    func readsBeforeCursor() throws {
        let text = "one\ntwo\nthree\n"
        let rows = try Self.rows(of: text, endOffset: 8, chunkSize: 2)
        #expect(rows.map(\.text) == ["two", "one"])
    }

    @Test("Oversized rows are dropped and their neighbors keep exact offsets", arguments: [1, 4, 5, 64 * 1024])
    func oversizedRowsAreDropped(chunkSize: Int) throws {
        let long = String(repeating: "x", count: 40)
        let text = "\(long)\nshort\n\(long)\nlast\n"
        let rows = try Self.rows(of: text, chunkSize: chunkSize, maximumRowBytes: 16)
        #expect(rows.map(\.text) == ["last", "short"])
        #expect(rows.map(\.startOffset) == [UInt64(text.utf8.count - 5), 41])
    }

    @Test("An empty log has no rows")
    func emptyLog() throws {
        #expect(try Self.rows(of: "", chunkSize: 4).isEmpty)
    }

    private struct DecodedRow: Equatable {
        let text: String
        let startOffset: UInt64
    }

    private static func rows(
        of text: String,
        endOffset: UInt64? = nil,
        chunkSize: Int,
        maximumRowBytes: Int = WorkstreamLogBackwardReader.defaultMaximumRowBytes
    ) throws -> [DecodedRow] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-reader-\(UUID().uuidString).jsonl")
        try Data(text.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var reader = WorkstreamLogBackwardReader(
            handle: handle,
            endOffset: endOffset ?? UInt64(text.utf8.count),
            chunkSize: chunkSize,
            maximumRowBytes: maximumRowBytes
        )
        var rows: [DecodedRow] = []
        while let row = try reader.next() {
            rows.append(DecodedRow(text: String(decoding: row.bytes, as: UTF8.self), startOffset: row.startOffset))
        }
        return rows
    }
}
