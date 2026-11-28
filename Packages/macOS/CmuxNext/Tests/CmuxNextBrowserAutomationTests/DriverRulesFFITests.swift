import Foundation
import Testing
@testable import CmuxNextBrowserAutomation

/// The driver's rules answered by Rust (cmux-browser-rules `driver.rs`) keep the texts and
/// meanings the Swift copy had.
@Suite struct DriverRulesFFITests {
    private func params(_ fields: [String: DriverJSON]) throws -> DriverParams {
        try DriverParams(method: "page.goto", json: .object(fields))
    }

    private func message(_ body: () throws(DriverError) -> Void) -> String? {
        do throws(DriverError) {
            try body()
            return nil
        } catch {
            return error.message
        }
    }

    @Test func paramsMustBeAnObjectOrNull() throws {
        #expect(message { _ = try DriverParams(method: "page.goto", json: .string("x")) } == "page.goto: params must be an object")
        let empty = try DriverParams(method: "page.goto", json: .null)
        #expect(!empty.has("url"))
    }

    @Test func readsNameTheMethodFieldAndType() throws {
        let call = try params(["url": .number(1), "flag": .string("yes"), "list": .array([.string("a"), .number(2)])])
        #expect(message { _ = try call.string("url") } == "page.goto: url: expected a string, got a number")
        #expect(message { _ = try call.string("missing") } == "page.goto: missing: expected a string")
        #expect(message { _ = try call.bool("flag") } == "page.goto: flag: expected a boolean, got a string")
        #expect(message { _ = try call.strings("list") } == "page.goto: list: expected an array of strings, got an array")
        #expect(message { _ = try call.array("flag") } == "page.goto: flag: expected an array, got a string")
    }

    @Test func nullReadsAsAbsent() throws {
        let call = try params(["url": .null, "flag": .null])
        #expect(!call.has("url"))
        #expect(call["url"] == nil)
        #expect(try call.optionalString("url") == nil)
        #expect(try call.bool("flag", default: true))
        #expect(try call.strings("url").isEmpty)
    }

    @Test func readsReturnTheirValues() throws {
        let call = try params(["url": .string("https://a.test"), "n": .number(2.5), "on": .bool(true),
                               "names": .array([.string("a"), .string("b")]), "items": .array([.number(1), .object([:])])])
        #expect(try call.string("url") == "https://a.test")
        #expect(try call.number("n") == 2.5)
        #expect(try call.bool("on"))
        #expect(try call.strings("names") == ["a", "b"])
        #expect(try call.array("items") == [.number(1), .object([:])])
        #expect(try call.timeout() == .seconds(30))
        #expect(try call.timeout(default: .milliseconds(250)) == .milliseconds(250))
    }

    @Test func aNonFiniteNumberIsRefused() throws {
        let call = try params(["n": .number(.nan), "timeoutMs": .number(.infinity)])
        #expect(message { _ = try call.number("n") } == "page.goto: n: expected a finite number, got a number")
        #expect(message { _ = try call.timeout() } == "page.goto: timeoutMs: expected a finite number, got a number")
    }

    @Test func theTimeoutMessageNamesItsSeconds() {
        #expect(CallDeadline.deadline(milliseconds: 1_500, what: "frame.evaluate").message
            == "frame.evaluate: Timeout 1.5 seconds exceeded")
        #expect(DriverParams.duration(milliseconds: 1_499.6) == .milliseconds(1_500))
    }

    @Test func tabPlaceReadsWorkspaceAndTerminal() {
        let place = AutomationTabPlace(.object(["callerWorkspace": .string("w1"), "callerTerminal": .string("t1"), "url": .string("")]))
        #expect(place.workspace == "w1")
        #expect(place.terminal == "t1")
        let none = AutomationTabPlace(.object(["callerWorkspace": .string(""), "callerTerminal": .number(1)]))
        #expect(none.workspace == nil)
        #expect(none.terminal == nil)
    }
}
