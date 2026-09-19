import Foundation
import Testing

@testable import CmuxTextActions

/// Pure value behaviour of `type: "text"` action payloads: sanitisation,
/// delivery plan, trust requirement, and JSON defaults.
struct CmuxTextActionPayloadTests {

    // MARK: - Sanitisation

    @Test func sanitizedTextStripsBidiAndZeroWidthControlsButKeepsLayout() {
        let raw = "  git status\u{200B}\n\tgit diff\u{202E} --stat\n"
        #expect(CmuxTextActionPayload.sanitizedText(raw) == "  git status\n\tgit diff --stat\n")
    }

    @Test func sanitizedTextRejectsBlankOrControlOnlyInput() {
        #expect(CmuxTextActionPayload.sanitizedText("") == nil)
        #expect(CmuxTextActionPayload.sanitizedText("  \n\t ") == nil)
        #expect(CmuxTextActionPayload.sanitizedText("\u{200B}\u{FEFF}") == nil)
    }

    @Test func initializerSanitisesAndRejectsBlankText() throws {
        #expect(CmuxTextActionPayload(text: "   ", submit: true) == nil)
        #expect(CmuxTextActionPayload(text: "\u{200B}", submit: false) == nil)
        let payload = try #require(CmuxTextActionPayload(text: "ls\u{200B} -la", submit: false))
        #expect(payload.text == "ls -la")
    }

    // MARK: - Delivery plan

    @Test func insertOnlyPayloadPastesWithoutSubmitting() throws {
        let payload = try #require(CmuxTextActionPayload(text: "review this diff for regressions", submit: false))
        #expect(payload.deliverySteps == [.pasteText("review this diff for regressions")])
        #expect(payload.requiresProjectTrust == false)
    }

    @Test func submitPayloadPastesThenPressesEnter() throws {
        let payload = try #require(CmuxTextActionPayload(text: "npm test", submit: true))
        #expect(payload.deliverySteps == [
            .pasteText("npm test"),
            .namedKey(CmuxTextActionPayload.submitKeyName)
        ])
        #expect(CmuxTextActionPayload.submitKeyName == "enter")
        #expect(payload.requiresProjectTrust == true)
    }

    @Test func multiLineTextIsDeliveredAsOnePasteChunk() throws {
        let text = "line one\nline two\n  indented three"
        let payload = try #require(CmuxTextActionPayload(text: text, submit: false))
        #expect(payload.deliverySteps == [.pasteText(text)])
    }

    // MARK: - Identifier slug

    @Test func identifierSlugIsFilesystemSafeAndBounded() throws {
        let payload = try #require(CmuxTextActionPayload(text: "echo \"hi there\" && ls -la /tmp", submit: false))
        let slug = payload.identifierSlug
        #expect(!slug.isEmpty)
        #expect(slug.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-%")).contains($0)
        })

        let long = try #require(CmuxTextActionPayload(text: String(repeating: "a", count: 500), submit: false))
        #expect(long.identifierSlug.count <= CmuxTextActionPayload.identifierSlugMaxLength)
    }

    // MARK: - Codable

    @Test func decodingDefaultsSubmitToFalse() throws {
        let payload = try JSONDecoder().decode(
            CmuxTextActionPayload.self,
            from: Data(#"{"text":"hello"}"#.utf8)
        )
        #expect(payload.text == "hello")
        #expect(payload.submit == false)
    }

    @Test func decodingSanitisesTextAndRejectsBlank() throws {
        let payload = try JSONDecoder().decode(
            CmuxTextActionPayload.self,
            from: Data(#"{"text":"hi​ there","submit":true}"#.utf8)
        )
        #expect(payload.text == "hi there")
        #expect(payload.submit == true)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CmuxTextActionPayload.self, from: Data(#"{"text":"   "}"#.utf8))
        }
    }

    @Test func encodingRoundTripsAndOmitsDefaultSubmit() throws {
        let original = try #require(CmuxTextActionPayload(text: "a\nb", submit: false))
        let data = try JSONEncoder().encode(original)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("submit"))
        let decoded = try JSONDecoder().decode(CmuxTextActionPayload.self, from: data)
        #expect(decoded == original)

        let submitting = try #require(CmuxTextActionPayload(text: "x", submit: true))
        let submittingData = try JSONEncoder().encode(submitting)
        let roundTripped = try JSONDecoder().decode(CmuxTextActionPayload.self, from: submittingData)
        #expect(roundTripped == submitting)
    }
}
