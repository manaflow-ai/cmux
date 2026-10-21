import Foundation
import Testing
@testable import CmuxNextDaemon

struct SendInputRequestTests {
    @Test func aGuardedSendNamesTheForegroundItExpects() throws {
        let request = SendInputRequest(surface: SurfaceID(rawValue: 7), text: "yes", paste: true,
                                       expectForeground: "/usr/local/bin/claude")
        let data = try WireCoding.encodeRequest(request, id: 3)
        let fields = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(fields == .object([
            "id": .number(3), "cmd": .string("send"), "surface": .number(7), "text": .string("yes"),
            "paste": .bool(true), "expect_foreground": .string("/usr/local/bin/claude"),
        ]))
    }

    /// An unguarded send stays byte for byte what every daemon already reads.
    @Test func anUnguardedSendCarriesNoForegroundField() throws {
        let data = try WireCoding.encodeRequest(SendInputRequest(surface: SurfaceID(rawValue: 7), text: "\r"), id: 4)
        let fields = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(fields == .object(["id": .number(4), "cmd": .string("send"), "surface": .number(7), "text": .string("\r")]))
    }
}
