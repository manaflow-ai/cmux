import Foundation
import Testing
@testable import CmuxCloudMachines

struct CloudGuestFilePreviewRequestTests {
    @Test func acceptsBoundedAbsoluteRemotePath() throws {
        let request = CloudGuestFilePreviewRequest(data: try wire(path: "/srv/project/notes.md", line: 12))
        #expect(request?.path == "/srv/project/notes.md")
        #expect(request?.line == 12)
    }

    @Test(arguments: ["notes.md", "/tmp/a\nb", String(repeating: "/", count: 16_385)])
    func rejectsRelativeControlAndOversizedPaths(_ path: String) throws {
        #expect(CloudGuestFilePreviewRequest(data: try wire(path: path)) == nil)
    }

    @Test func rejectsInvalidLineAndEnvelope() throws {
        #expect(CloudGuestFilePreviewRequest(data: try wire(path: "/tmp/a", line: 0)) == nil)
        #expect(CloudGuestFilePreviewRequest(data: try wire(path: "/tmp/a", event: "url-open")) == nil)
    }

    private func wire(path: String, line: Int? = nil, event: String = "file-preview-open") throws -> Data {
        var value: [String: Any] = [
            "event": event,
            "request_id": UUID().uuidString,
            "terminal_id": "term_0123456789abcdef0123456789abcdef",
            "path": path
        ]
        if let line { value["line"] = line }
        return try JSONSerialization.data(withJSONObject: value)
    }
}
