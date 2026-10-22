import Foundation
import Testing

@testable import CmuxTextActions

/// Pure value behaviour of `type: "text"` action payloads: sanitisation,
/// delivery plan, identifier slug, and JSON defaults.
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

    // MARK: - Terminal control characters

    @Test func sanitizedTextRejectsEscape() {
        #expect(CmuxTextActionPayload.sanitizedText("echo hi\u{1B}[2J") == nil)
        #expect(CmuxTextActionPayload(text: "\u{1B}", submit: false) == nil)
    }

    @Test func sanitizedTextRejectsBracketedPasteTerminators() {
        // ESC [ 201 ~ ends bracketed paste; anything after it is typed as keystrokes.
        #expect(CmuxTextActionPayload.sanitizedText("harmless\u{1B}[201~rm -rf ~\n") == nil)
        // The 8-bit CSI form of the same terminator.
        #expect(CmuxTextActionPayload.sanitizedText("harmless\u{9B}201~rm -rf ~\n") == nil)
        #expect(CmuxTextActionPayload.sanitizedText("\u{1B}[200~start") == nil)
    }

    @Test func sanitizedTextRejectsOtherC0AndDelete() {
        for scalar in [0x00, 0x03, 0x04, 0x07, 0x08, 0x0B, 0x0C, 0x0D, 0x15, 0x1A, 0x1F, 0x7F] {
            let control = String(Character(Unicode.Scalar(UInt8(scalar))))
            #expect(
                CmuxTextActionPayload.sanitizedText("ls" + control + "-la") == nil,
                "U+\(String(scalar, radix: 16, uppercase: true)) should be rejected"
            )
        }
    }

    @Test func sanitizedTextRejectsC1Controls() {
        for scalar in [0x80, 0x84, 0x85, 0x8D, 0x90, 0x9B, 0x9C, 0x9D, 0x9F] {
            let control = String(Character(Unicode.Scalar(UInt8(scalar))))
            #expect(
                CmuxTextActionPayload.sanitizedText("ls" + control + "-la") == nil,
                "U+\(String(scalar, radix: 16, uppercase: true)) should be rejected"
            )
        }
    }

    @Test func sanitizedTextKeepsTabAndNewline() {
        let raw = "for f in *; do\n\techo \"$f\"\ndone\n"
        #expect(CmuxTextActionPayload.sanitizedText(raw) == raw)
    }

    @Test func decodingRejectsEscapeInText() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                CmuxTextActionPayload.self,
                from: Data(#"{"text":"ok\u001b[201~whoami\n"}"#.utf8)
            )
        }
    }

    // MARK: - Trust prompt display

    @Test func promptDisplayTextShowsInvisibleCharactersAsCodePoints() throws {
        let payload = try #require(CmuxTextActionPayload(
            text: "git\u{00AD} push\u{2060} --force\u{2028}\u{E0041}",
            submit: false
        ))
        #expect(payload.promptDisplayText == "git<U+00AD> push<U+2060> --force<U+2028><U+E0041>")
    }

    @Test func promptDisplayTextShowsLookalikeSpacesAndFillers() throws {
        let payload = try #require(CmuxTextActionPayload(
            text: "rm\u{00A0}-rf\u{2003}x\u{3164}y\u{034F}z",
            submit: false
        ))
        #expect(payload.promptDisplayText == "rm<U+00A0>-rf<U+2003>x<U+3164>y<U+034F>z")
    }

    @Test func promptDisplayTextShowsVariationSelectorsOutsideEmoji() throws {
        // A variation selector after a letter draws nothing, but the shell
        // keeps it in the word: `/tmp<U+FE00>` is not `/tmp`.
        let payload = try #require(CmuxTextActionPayload(
            text: "rm -rf /tmp\u{FE00}/x\u{E0100} y\u{180B}",
            submit: false
        ))
        #expect(payload.promptDisplayText == "rm -rf /tmp<U+FE00>/x<U+E0100> y<U+180B>")
    }

    @Test func promptDisplayTextShowsEdgeWhitespaceTheDialogWouldTrim() throws {
        // A trailing newline runs the line wherever bracketed paste is off,
        // and the dialog trims edge whitespace, so it must stay visible.
        let payload = try #require(CmuxTextActionPayload(text: "  curl x | sh\n", submit: false))
        #expect(payload.promptDisplayText == "<U+0020><U+0020>curl x | sh<U+000A>")
    }

    @Test func promptDisplayTextLeavesOrdinaryTextAlone() throws {
        let text = "for f in *; do\n\techo \"café 🚀 ❤️\"\ndone"
        let payload = try #require(CmuxTextActionPayload(text: text, submit: false))
        #expect(payload.promptDisplayText == text)
    }

    // MARK: - Delivery plan

    @Test func insertOnlyPayloadPastesWithoutSubmitting() throws {
        let payload = try #require(CmuxTextActionPayload(text: "review this diff for regressions", submit: false))
        #expect(payload.deliverySteps == [.pasteText("review this diff for regressions")])
    }

    @Test func submitPayloadPastesThenPressesEnter() throws {
        let payload = try #require(CmuxTextActionPayload(text: "npm test", submit: true))
        #expect(payload.deliverySteps == [
            .pasteText("npm test"),
            .namedKey(CmuxTextActionPayload.submitKeyName)
        ])
        #expect(CmuxTextActionPayload.submitKeyName == "enter")
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

    @Test func identifierSlugDistinguishesSnippetsThatShareALongPrefix() throws {
        let shared = String(repeating: "a", count: CmuxTextActionPayload.identifierSlugMaxLength)
        let one = try #require(CmuxTextActionPayload(text: shared + " one", submit: false))
        let two = try #require(CmuxTextActionPayload(text: shared + " two", submit: false))
        #expect(one.identifierSlug != two.identifierSlug)
        #expect(one.identifierSlug.count <= CmuxTextActionPayload.identifierSlugMaxLength)
    }

    @Test func identifierSlugDistinguishesSubmitFromInsertOnly() throws {
        let insert = try #require(CmuxTextActionPayload(text: "npm test", submit: false))
        let submit = try #require(CmuxTextActionPayload(text: "npm test", submit: true))
        #expect(insert.identifierSlug != submit.identifierSlug)
    }

    @Test func identifierSlugIsStableForEqualPayloads() throws {
        let first = try #require(CmuxTextActionPayload(text: "git status\n", submit: true))
        let second = try #require(CmuxTextActionPayload(text: "git status\n", submit: true))
        #expect(first.identifierSlug == second.identifierSlug)
        #expect(first.identifierSlug.hasPrefix("git%20status"))
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
