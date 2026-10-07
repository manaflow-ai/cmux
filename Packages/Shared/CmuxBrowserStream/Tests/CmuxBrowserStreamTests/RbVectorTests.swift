import CmuxBrowserStream
import CmuxMobileWire
import Foundation
import Testing

/// Replays `schemas/remote-tab/messages.json`, the file cmux-remote-browser
/// replays: every modeled message decodes and re-encodes to the same value.
@Suite("cmux.rb/1 messages (schemas/remote-tab/messages.json)")
struct RbVectorTests {
    static let file: JSONValue = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("schemas/remote-tab/messages.json")
        let data = (try? Data(contentsOf: url)) ?? Data()
        return (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
    }()

    @Test func everyControlMessageDecodesAndModeledOnesRoundTrip() throws {
        guard case .array(let control)? = Self.file["control"] else {
            Issue.record("messages.json missing")
            return
        }
        #expect(control.count > 40)
        var modeled = 0
        for value in control {
            let message = try RbControl(json: value)
            if case .unmodeled = message { continue }
            modeled += 1
            #expect(Self.normalized(message.jsonValue) == Self.normalized(value), "\(value)")
        }
        #expect(modeled >= 20)
    }

    @Test func navigateMessagesAreInTheSharedFile() throws {
        guard case .array(let control)? = Self.file["control"] else { return }
        let tags = control.compactMap { $0["t"]?.stringValue }
        #expect(tags.contains("rb.navigate"))
        #expect(tags.contains("rb.navigate.result"))
    }

    @Test func everyInputEventRoundTrips() throws {
        guard case .array(let input)? = Self.file["input"] else {
            Issue.record("messages.json missing")
            return
        }
        for value in input {
            let event = try RbInputEvent(json: value)
            #expect(Self.normalized(event.jsonValue) == Self.normalized(value), "\(value)")
            #expect(try RbInputEvent(rdEvent: try event.rdEvent()) == event)
        }
    }

    @Test func unknownTagsOutsideRbAreRefused() {
        #expect(throws: RdWireError.self) { try RbControl(json: .object(["t": .string("hello")])) }
    }

    /// Numbers compare as doubles (`2.0` decodes as an integer).
    static func normalized(_ value: JSONValue) -> JSONValue {
        switch value {
        case .int(let v): .double(Double(v))
        case .array(let items): .array(items.map(normalized))
        case .object(let object): .object(object.mapValues(normalized))
        default: value
        }
    }
}
