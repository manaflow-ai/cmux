import Foundation
import Testing
@testable import CmuxMobileWire

@Suite struct FrameFixtureTests {
    let fixtures = Fixtures()

    @Test func everyFrameTypeHasAnExample() throws {
        let frames = try #require(fixtures.json("fixtures/frames.json")["frames"]?.arrayValue)
        let types = Set(frames.compactMap { $0["t"]?.stringValue })
        #expect(types == Set(MobileFrameType.allCases.map(\.rawValue)))
    }

    @Test func framesRoundTrip() throws {
        let frames = try #require(fixtures.json("fixtures/frames.json")["frames"]?.arrayValue)
        for frame in frames {
            let decoded = try MobileFrame(value: frame)
            #expect(try decoded.jsonValue == frame, "\(frame)")
            #expect(decoded.type.rawValue == frame["t"]?.stringValue)
            let reparsed = try MobileFrame(decoding: decoded.encoded())
            #expect(reparsed == decoded)
        }
    }

    @Test func refusesUnknownAndMalformedFrames() throws {
        #expect(throws: MobileWireError(code: "proto.unknown_frame", message: "unknown frame x-new")) {
            try MobileFrame(value: .object(["t": .string("x-new")]))
        }
        do {
            _ = try MobileFrame(value: .object(["t": .string("op"), "op": .string("host.wake")]))
            Issue.record("a frame without its required members decoded")
        } catch let error as MobileWireError {
            #expect(error.code == "validation.invalid")
        }
        let wrongProto: JSONValue = .object([
            "t": .string("hello"), "proto": .string("cmux.mobile/9"), "min": .int(1), "max": .int(1), "caps": .array([]),
            "client": .object(["install": .string("in_phone01"), "platform": .string("ios"), "app_version": .string("1")]),
        ])
        do {
            _ = try MobileFrame(value: wrongProto)
            Issue.record("a hello with another proto decoded")
        } catch let error as MobileWireError {
            #expect(error.code == "proto.version_unsupported")
        }
    }

    @Test func typedFramesEncodeTheWireShape() throws {
        let hello = MobileFrame.hello(HelloFrame(caps: ["terminal-snapshot-v1"],
                                                 client: HelloClient(install: "in_phone01", platform: "ios", appVersion: "1.0.0")))
        let json = try hello.jsonValue
        #expect(json["proto"]?.stringValue == "cmux.mobile/1")
        #expect(json["client"]?["app_version"]?.stringValue == "1.0.0")
        let open = MobileFrame.channelOpen(ChannelOpenFrame(channel: 3, kind: .terminal, channelClass: .interactive, window: 262_144, params: [:]))
        #expect(try open.jsonValue["class"]?.stringValue == "interactive")
        #expect(open.messageName == "terminal")
    }
}
