import CmuxMobileShellModel
import Foundation
import Testing

@testable import CmuxMobileShell

/// Verifies the pure multipart body the email feedback path POSTs to the web
/// `/api/feedback` route: the field names the route's zod schema reads, and that
/// the build stamp is mapped onto those fields so the email is self-identifying.
struct MobileFeedbackEmailClientTests {
    private func decodedFields(_ body: Data, boundary: String) -> [String: String] {
        let text = String(decoding: body, as: UTF8.self)
        var fields: [String: String] = [:]
        // Split on the boundary; each part carries one form field.
        for part in text.components(separatedBy: "--\(boundary)") {
            guard let nameRange = part.range(of: "name=\"") else { continue }
            let afterName = part[nameRange.upperBound...]
            guard let closeQuote = afterName.firstIndex(of: "\"") else { continue }
            let name = String(afterName[..<closeQuote])
            // The value follows the blank line after the headers.
            guard let valueRange = part.range(of: "\r\n\r\n") else { continue }
            let rawValue = String(part[valueRange.upperBound...])
            let value = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n-"))
            fields[name] = value
        }
        return fields
    }

    @Test func multipartBodyCarriesMessageAndStampFields() {
        let stamp = MobileFeedbackStamp(
            buildType: .beta,
            appVersion: "0.64.13",
            appBuild: "42",
            bundleIdentifier: "dev.cmux.app.beta",
            osVersion: "iOS 18.5",
            deviceModel: "iPhone16,2"
        )
        let boundary = "Boundary-TEST"
        let body = MobileFeedbackEmailClient.multipartBody(
            email: "lawrence@manaflow.ai",
            message: "the terminal froze",
            stamp: stamp,
            boundary: boundary
        )
        let fields = decodedFields(body, boundary: boundary)

        #expect(fields["email"] == "lawrence@manaflow.ai")
        #expect(fields["message"] == "the terminal froze")
        #expect(fields["buildType"] == "beta")
        #expect(fields["appVersion"] == "0.64.13")
        #expect(fields["appBuild"] == "42")
        #expect(fields["bundleIdentifier"] == "dev.cmux.app.beta")
        #expect(fields["osVersion"] == "iOS 18.5")
        #expect(fields["hardwareModel"] == "iPhone16,2")
        #expect(fields["locale"] != nil)
    }

    @Test func multipartBodyIsTerminated() {
        let stamp = MobileFeedbackStamp(
            buildType: .prod, appVersion: "", appBuild: "",
            bundleIdentifier: "", osVersion: "", deviceModel: ""
        )
        let body = MobileFeedbackEmailClient.multipartBody(
            email: "a@b.com",
            message: "hi",
            stamp: stamp,
            boundary: "B"
        )
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.hasSuffix("--B--\r\n"))
    }

    @Test func clientInitJoinsApiPath() {
        // A valid base URL produces a usable client; trailing slash is tolerated.
        #expect(MobileFeedbackEmailClient(apiBaseURL: "https://cmux.dev") != nil)
        #expect(MobileFeedbackEmailClient(apiBaseURL: "https://cmux.dev/") != nil)
    }
}
