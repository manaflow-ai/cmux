import CmuxTerminalStream
import Foundation
import Testing
@testable import CmuxMobileWire

@Suite struct BinaryVectorTests {
    static let doc: JSONValue = (try? Fixtures().json("fixtures/binary.json")) ?? .null
    static let records: [JSONValue] = doc["records"]?.arrayValue ?? []
    static let streams: [JSONValue] = doc["streams"]?.arrayValue ?? []
    static let invalidRecords: [JSONValue] = doc["invalid_records"]?.arrayValue ?? []
    static let invalidStreams: [JSONValue] = doc["invalid_streams"]?.arrayValue ?? []

    @Test func vectorsLoadedAndMaxRecordMatches() {
        #expect(Self.records.count >= 10)
        #expect(Self.doc["max_record"]?.intValue == StreamRecord.maxRecord)
    }

    @Test(arguments: records)
    func recordDecodesAndEncodesByteExact(vector: JSONValue) throws {
        let hex = try #require(vector["hex"]?.stringValue)
        let record = try StreamRecord(decoding: Data(hex: hex))
        #expect(Int(record.channel) == vector["channel"]?.intValue)
        #expect(Int(record.seq) == vector["seq"]?.intValue)
        let flagNames = (vector["flags"]?.arrayValue ?? []).compactMap(\.stringValue)
        #expect(record.flags.names == flagNames)
        let payload = try #require(vector["payload"]?.objectValue?.first)
        let f = payload.value
        let rebuilt: StreamRecord
        switch payload.key {
        case "terminal_input":
            let input = try TerminalInput(decoding: record.payload)
            #expect(input.kind == (f["kind"]?.stringValue == "paste" ? .paste : .bytes))
            #expect(input.data.hex == f["data_hex"]?.stringValue)
            let kind: TerminalInputKind = f["kind"]?.stringValue == "paste" ? .paste : .bytes
            let encoded = TerminalInput(kind: kind, data: Data(hex: f["data_hex"]!.stringValue!)).encoded
            rebuilt = StreamRecord(channel: record.channel, seq: record.seq, flags: RecordFlags(names: flagNames), payload: encoded)
        case "terminal_output":
            // terminal-snapshot-v1 output is CmuxTerminalStream's TerminalFrame, unchanged.
            let frame = try TerminalFrame(decoding: record.payload)
            let kinds: [String: TerminalFrame.Kind] = ["bytes": .bytes, "snapshot_ready": .snapshotReady,
                                                       "snapshot_history": .snapshotHistory, "digest": .digest]
            let kind = try #require(kinds[f["kind"]?.stringValue ?? ""])
            #expect(frame.kind == kind)
            #expect(Int(frame.generation) == f["generation"]?.intValue)
            #expect(Int(frame.offset) == f["offset"]?.intValue)
            #expect(frame.snapshotVersion.map(Int.init) == f["snapshot_version"]?.intValue)
            #expect(frame.payload.hex == f["data_hex"]?.stringValue)
            #expect(record.flags.contains(.keyframe) == (kind == .snapshotReady))
            let encoded = TerminalFrame(kind: kind, generation: frame.generation, offset: frame.offset,
                                        snapshotVersion: frame.snapshotVersion, payload: Data(hex: f["data_hex"]!.stringValue!)).encoded
            rebuilt = StreamRecord(channel: record.channel, seq: record.seq, flags: RecordFlags(names: flagNames), payload: encoded)
        case "credit":
            let grant = try record.credit()
            #expect(Int(grant.ackSeq) == f["ack_seq"]?.intValue)
            #expect(Int(grant.grantBytes) == f["grant_bytes"]?.intValue)
            rebuilt = .credit(channel: record.channel, grant: grant)
        case "file_chunk":
            let chunk = try FileChunk(decoding: record.payload)
            #expect(Int(chunk.offset) == f["offset"]?.intValue)
            #expect(chunk.data.hex == f["data_hex"]?.stringValue)
            rebuilt = StreamRecord(channel: record.channel, seq: record.seq, payload: chunk.encoded)
        case "rd":
            let frame = try RdStreamFrame(decoding: record.payload)
            #expect(Int(frame.type.rawValue) == f["type"]?.intValue)
            #expect(frame.data.hex == f["data_hex"]?.stringValue)
            rebuilt = StreamRecord(channel: record.channel, seq: record.seq, payload: frame.encoded)
        case "bytes":
            // tcp.data: the payload is the TCP bytes unchanged.
            #expect(record.payload.hex == f["data_hex"]?.stringValue)
            rebuilt = StreamRecord(channel: record.channel, seq: record.seq, flags: RecordFlags(names: flagNames),
                                   payload: Data(hex: f["data_hex"]!.stringValue!))
        case "json":
            #expect(try record.jsonObject() == f)
            let decoded = try MobileJSON(value: f)
            #expect(try decoded.jsonValue == f)
            rebuilt = try .json(channel: record.channel, seq: record.seq, object: f, flags: RecordFlags(names: flagNames))
        default:
            Issue.record("unknown payload \(payload.key)")
            return
        }
        #expect(rebuilt.encoded.hex == hex)
        if let name = vector["message"]?.stringValue {
            #expect(MobileCatalog.v1.message(named: name)?.plane == .stream)
        }
    }

    @Test(arguments: streams)
    func deframerSplitsAtEveryChunkSize(vector: JSONValue) throws {
        let all = Data(hex: try #require(vector["hex"]?.stringValue))
        let expected = (vector["records"]?.arrayValue ?? []).compactMap(\.stringValue)
        for size in 1...all.count {
            var deframer = RecordDeframer()
            var got: [String] = []
            var at = 0
            while at < all.count {
                let end = min(at + size, all.count)
                got += try deframer.push(all.subdata(in: at..<end)).map(\.encoded.hex)
                at = end
            }
            #expect(got == expected, "chunk size \(size)")
        }
        let reframed = try expected.map { try StreamRecord(decoding: Data(hex: $0)).framed.hex }.joined()
        #expect(reframed == vector["hex"]?.stringValue)
    }

    @Test(arguments: invalidRecords)
    func refusesInvalidRecords(vector: JSONValue) throws {
        let reason = try #require(RecordErrorReason(rawValue: vector["error"]?.stringValue ?? ""))
        let bytes = Data(hex: try #require(vector["hex"]?.stringValue))
        do throws(RecordError) {
            _ = try StreamRecord(decoding: bytes)
            Issue.record("\(vector["name"]?.stringValue ?? "") decoded")
        } catch {
            #expect(error.reason == reason)
        }
    }

    @Test(arguments: invalidStreams)
    func deframerRefusesAndStaysFailed(vector: JSONValue) throws {
        let reason = try #require(RecordErrorReason(rawValue: vector["error"]?.stringValue ?? ""))
        var deframer = RecordDeframer()
        let bytes = Data(hex: try #require(vector["hex"]?.stringValue))
        do throws(RecordError) {
            _ = try deframer.push(bytes)
            Issue.record("\(vector["name"]?.stringValue ?? "") deframed")
        } catch {
            #expect(error.reason == reason)
        }
        #expect(throws: RecordError.self) { _ = try deframer.push(Data()) }
    }
}
