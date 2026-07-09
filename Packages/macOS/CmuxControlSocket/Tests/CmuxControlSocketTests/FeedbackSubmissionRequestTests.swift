import Foundation
import Testing
@testable import CmuxControlSocket

@Suite("FeedbackSubmissionRequest")
struct FeedbackSubmissionRequestTests {
    @Test("valid params parse all three fields")
    func validParse() throws {
        let request = try FeedbackSubmissionRequest(params: [
            "email": "a@b.com",
            "body": "hello",
            "image_paths": ["/tmp/a.png", "/tmp/b.png"],
        ])
        #expect(request.email == "a@b.com")
        #expect(request.body == "hello")
        #expect(request.imagePaths == ["/tmp/a.png", "/tmp/b.png"])
    }

    @Test("missing or non-string email names the email field")
    func missingEmail() {
        #expect(throws: FeedbackSubmissionRequest.ParseError.missingEmail) {
            _ = try FeedbackSubmissionRequest(params: ["body": "hi"])
        }
        #expect(throws: FeedbackSubmissionRequest.ParseError.missingEmail) {
            _ = try FeedbackSubmissionRequest(params: ["email": 5, "body": "hi"])
        }
        #expect(FeedbackSubmissionRequest.ParseError.missingEmail.field == "email")
        #expect(FeedbackSubmissionRequest.ParseError.missingEmail.message == "Missing email")
    }

    @Test("missing or non-string body names the body field")
    func missingBody() {
        #expect(throws: FeedbackSubmissionRequest.ParseError.missingBody) {
            _ = try FeedbackSubmissionRequest(params: ["email": "a@b.com"])
        }
        #expect(FeedbackSubmissionRequest.ParseError.missingBody.field == "body")
        #expect(FeedbackSubmissionRequest.ParseError.missingBody.message == "Missing body")
    }

    @Test("absent or wrong-typed image_paths defaults to empty")
    func imagePathsDefault() throws {
        let absent = try FeedbackSubmissionRequest(params: ["email": "a@b.com", "body": "hi"])
        #expect(absent.imagePaths == [])
        let wrongType = try FeedbackSubmissionRequest(params: [
            "email": "a@b.com", "body": "hi", "image_paths": "nope",
        ])
        #expect(wrongType.imagePaths == [])
    }
}
