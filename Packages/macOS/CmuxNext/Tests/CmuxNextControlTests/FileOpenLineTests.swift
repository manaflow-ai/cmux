@testable import CmuxNextControl
import CmuxNextSettings
import Testing

struct FileOpenLineTests {
    @Test(arguments: ["42", "42:7", "42-50", "10000000"])
    func fileOpenAcceptsTheSharedLocation(_ text: String) throws {
        let request = try FileOpenRequest(["path": "/repo/app.ts", "line": .string(text)], method: "file.open")
        #expect(request.line?.argument == text)
        #expect(request.paths == ["/repo/app.ts"])
    }

    @Test(arguments: ["0", "-1", "42:0", "1.5", "42-1", "10000001", "42;command"])
    func fileOpenRefusesInvalidLocations(_ text: String) {
        #expect(throws: (any Error).self) {
            try FileOpenRequest(["path": "/repo/app.ts", "line": .string(text)], method: "file.open")
        }
    }
    @Test(arguments: [JSONValue.bool(true), .number(42), .array([]), .string("0"), .string("10000001")])
    func invalidLineUsesTheLocalizedLineMessage(value: JSONValue) throws {
        do {
            _ = try FileOpenRequest(["path": "/repo/app.ts", "line": value], method: "file.open")
            Issue.record("invalid line was accepted")
        } catch let error as ControlError {
            #expect(error.code == "invalid_params")
            #expect(error.message == ControlStrings.text("control.error.invalidLine", "Line must be a number from 1 to 10,000,000, optionally followed by :column or -endLine."))
        }
    }

}
