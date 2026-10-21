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
}
