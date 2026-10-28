import Foundation
import Testing
import CmuxNextIPC

private enum GoldenError: Error {
    case noSpecDirectory
    case malformed(String)
}

/// One case of cmux-tui/spec/fixtures/ipc-hot-codec/golden.json.
private struct GoldenCase {
    let name: String
    let part: String
    let json: Data
    let bytes: [UInt8]
}

/// The hot-message codec CmuxNextWireGen's HotEmitter builds from cmux-tui/spec/sdk-schema.json
/// (p05-ipc-183): every layout writes the golden bytes the Rust codec writes
/// (cmux-tui/spec/fixtures/ipc-hot-codec/golden.json), reads them back to the value the JSON form
/// decodes to, writes that JSON form again, and refuses every payload that is not its layout.
@Suite struct HotCodecTests {
    private static func golden() throws -> [GoldenCase] {
        var root = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("cmux-tui/spec").path) {
            let parent = root.deletingLastPathComponent()
            guard parent.path != root.path else { throw GoldenError.noSpecDirectory }
            root = parent
        }
        let file = root.appendingPathComponent("cmux-tui/spec/fixtures/ipc-hot-codec/golden.json")
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        guard let cases = document?["cases"] as? [[String: Any]] else { throw GoldenError.malformed("no cases") }
        return try cases.map { entry in
            guard let name = entry["name"] as? String, let part = entry["part"] as? String,
                  let json = entry["json"], let hex = entry["hex"] as? String
            else { throw GoldenError.malformed("\(entry)") }
            return GoldenCase(name: name, part: part, json: try JSONSerialization.data(withJSONObject: json),
                              bytes: try bytes(hex))
        }
    }

    private static func bytes(_ hex: String) throws -> [UInt8] {
        let digits = Array(hex.utf8)
        guard digits.count.isMultiple(of: 2) else { throw GoldenError.malformed(hex) }
        return try stride(from: 0, to: digits.count, by: 2).map { index in
            guard let byte = UInt8(String(decoding: digits[index..<(index + 2)], as: UTF8.self), radix: 16) else {
                throw GoldenError.malformed(hex)
            }
            return byte
        }
    }

    private static func golden(_ name: String, _ part: String) throws -> [UInt8] {
        try #require(try golden().first { $0.name == name && $0.part == part }).bytes
    }

    /// The JSON form decodes to a value that writes the golden bytes, the bytes read back to that
    /// value, and the value writes the same JSON again.
    private static func expectGolden<Body: HotValue & Codable & Equatable>(_ layout: HotLayout<Body>, _ golden: GoldenCase) throws {
        let value = try JSONDecoder().decode(Body.self, from: golden.json)
        #expect(try layout.encode(value) == golden.bytes, "\(golden.name) \(golden.part)")
        #expect(try layout.decode(golden.bytes) == value, "\(golden.name) \(golden.part)")
        let again = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? NSDictionary
        let expected = try JSONSerialization.jsonObject(with: golden.json) as? NSDictionary
        #expect(again == expected, "\(golden.name) \(golden.part)")
    }

    @Test func everyLayoutWritesAndReadsTheGoldenBytes() throws {
        let cases = try Self.golden()
        for golden in cases {
            switch (golden.name, golden.part) {
            case ("resize-attached-view", "request"):
                try Self.expectGolden(HotLayout<HotResizeAttachedViewRequest>.resizeAttachedViewRequest, golden)
            case ("resize-attached-view", "result"):
                try Self.expectGolden(HotLayout<HotAttachedViewResizeResult>.resizeAttachedViewResult, golden)
            case ("set-client-sizing", "request"):
                try Self.expectGolden(HotLayout<HotSetClientSizingRequest>.setClientSizingRequest, golden)
            case ("set-client-sizing", "result"):
                try Self.expectGolden(HotLayout<HotEmptyResult>.setClientSizingResult, golden)
            case ("scroll-surface", "request"):
                try Self.expectGolden(HotLayout<HotScrollSurfaceRequest>.scrollSurfaceRequest, golden)
            case ("scroll-surface", "result"):
                try Self.expectGolden(HotLayout<HotEmptyResult>.scrollSurfaceResult, golden)
            case ("snapshot-request", "request"):
                try Self.expectGolden(HotLayout<HotSnapshotRequestRequest>.snapshotRequestRequest, golden)
            case ("snapshot-request", "result"):
                try Self.expectGolden(HotLayout<HotSnapshotRequestResult>.snapshotRequestResult, golden)
            case ("digest", "event"):
                try Self.expectGolden(HotLayout<HotDigestEvent>.digestEvent, golden)
            case ("scroll-changed", "event"):
                try Self.expectGolden(HotLayout<HotScrollChangedEvent>.scrollChangedEvent, golden)
            case ("size-state", "event"):
                try Self.expectGolden(HotLayout<HotSizeStateEvent>.sizeStateEvent, golden)
            case ("surface-resized", "event"):
                try Self.expectGolden(HotLayout<HotSurfaceResizedEvent>.surfaceResizedEvent, golden)
            default:
                Issue.record("no layout for golden case \(golden.name) \(golden.part)")
            }
        }
        // Every layout has a golden case.
        let covered = Set(cases.map { "\($0.name) \($0.part)" })
        #expect(covered == Set(HotLayoutInfo.schema.map { "\($0.name) \($0.part.rawValue)" }))
    }

    /// A layout is exactly the binary payload the method table gives its id; title-changed stays JSON.
    @Test func layoutsAgreeWithTheMethodTable() throws {
        let table = MethodTable.schema
        for info in HotLayoutInfo.schema {
            let expected = MethodPayload.binary(layoutVersion: info.layoutVersion)
            switch info.part {
            case .request, .result:
                // The Swift table keeps only `clients: macos` methods; scroll-surface is the SDK's.
                guard let method = table.v12(MethodID(rawValue: info.wireID)) else { continue }
                #expect(method.name == info.name && method.payload == expected, "\(info.name)")
            case .event:
                let event = try #require(table.event(EventID(rawValue: info.wireID)), "\(info.name)")
                #expect(event.name == info.name && event.payload == expected, "\(info.name)")
            }
        }
        let title = try #require(table.eventID(named: "title-changed").flatMap(table.event))
        #expect(title.payload == .json)
    }

    @Test func anotherLayoutVersionIsRefused() throws {
        var bytes = try Self.golden("scroll-surface", "request")
        bytes[0] = 2
        let layout = HotLayout<HotScrollSurfaceRequest>.scrollSurfaceRequest
        #expect(throws: HotDecodeError.version(name: "scroll-surface", expected: 1, found: 2)) { try layout.decode(bytes) }
        #expect(throws: HotDecodeError.truncated) { try layout.decode([UInt8]()) }
    }

    @Test func truncatedAndTrailingPayloadsAreRefused() throws {
        let bytes = try Self.golden("size-state", "event")
        let layout = HotLayout<HotSizeStateEvent>.sizeStateEvent
        for length in 0..<bytes.count {
            #expect(throws: HotDecodeError.self, "prefix \(length)") { try layout.decode(Array(bytes.prefix(length))) }
        }
        #expect(throws: HotDecodeError.trailingBytes(1)) { try layout.decode(bytes + [0]) }
    }

    @Test func badTagsBooleansEnumsAndStringsAreRefused() throws {
        // scroll-changed: version, at_bottom, cause tag, cause, offset, surface.
        let scroll = try Self.golden("scroll-changed", "event")
        let layout = HotLayout<HotScrollChangedEvent>.scrollChangedEvent
        var badBool = scroll
        badBool[1] = 7
        #expect(throws: HotDecodeError.badBool(7)) { try layout.decode(badBool) }
        var badTag = scroll
        badTag[2] = 2
        #expect(throws: HotDecodeError.badTag(2)) { try layout.decode(badTag) }
        var badEnum = scroll
        badEnum[3] = 9
        #expect(throws: HotDecodeError.badEnum(type: "EventCause", index: 9)) { try layout.decode(badEnum) }

        // resize-attached-view result: version, accepted, outcome, participant tag, u16 length, "p-7".
        let result = try Self.golden("resize-attached-view", "result")
        let resultLayout = HotLayout<HotAttachedViewResizeResult>.resizeAttachedViewResult
        var over = result
        over[4] = 0x01
        over[5] = 0x01
        #expect(throws: HotDecodeError.overBound(length: 257, max: 256)) { try resultLayout.decode(over) }
        var notUTF8 = result
        notUTF8[6] = 0xFF
        #expect(throws: HotDecodeError.invalidUTF8) { try resultLayout.decode(notUTF8) }
    }

    /// A value over its layout's bounds is refused, so the sender writes JSON instead.
    @Test func valuesOverTheirBoundsAreRefused() throws {
        let request = HotResizeAttachedViewRequest(cols: 80, rows: 24, surface: 1, view: String(repeating: "v", count: 129))
        #expect(throws: HotEncodeError.stringTooLong(length: 129, max: 128)) {
            try HotLayout<HotResizeAttachedViewRequest>.resizeAttachedViewRequest.encode(request)
        }
        let state = HotSizeState(cols: 80, generation: 1, owners: Array(repeating: "mac", count: 65), participants: [],
                                 policy: HotSizePolicy(), reason: .latest, rows: 24)
        #expect(throws: HotEncodeError.arrayTooLong(length: 65, max: 64)) {
            try HotLayout<HotSizeStateEvent>.sizeStateEvent.encode(HotSizeStateEvent(state: state, surface: 1))
        }
    }

    /// An unknown device kind in JSON reads as the schema's fallback, never as an error.
    @Test func anUnknownExtensibleEnumValueReadsAsItsFallback() throws {
        let kind = try JSONDecoder().decode([HotSizeDeviceKind].self, from: Data(#"["vision"]"#.utf8))
        #expect(kind == [.unknown])
    }
}
