import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// The composer's emoji shortcode lifecycle (EmojiShortcodes), every rule of the shared spec
/// (Mac composer: webviews/src/agent-session/acpmux/emojiShortcodes.ts). The cases named in the
/// brief are the ones the Mac's suite runs too, so both platforms agree.
@Suite struct EmojiShortcodesTests {
    static let table = EmojiShortcodeTable.bundled

    /// The composer as the field drives it: text, a caret, and each typed character's closing-colon check.
    struct Typing {
        var text = ""
        var caret = 0
        var prefs = EmojiPrefs()

        init(_ text: String = "", prefs: EmojiPrefs = EmojiPrefs()) {
            self.text = text
            caret = text.utf16.count
            self.prefs = prefs
        }

        mutating func apply(_ edit: EmojiEdit) {
            text = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
            caret = edit.caret
            if let tone = edit.rememberTone { prefs.tone = tone }
        }

        mutating func type(_ typed: String) {
            for character in typed {
                let piece = String(character)
                text = (text as NSString).replacingCharacters(in: NSRange(location: caret, length: 0), with: piece)
                caret += piece.utf16.count
                if piece == ":", let edit = EmojiShortcodes.closingColon(in: text, caret: caret, table: EmojiShortcodesTests.table, tone: prefs.tone) {
                    apply(edit)
                }
            }
        }

        var trigger: EmojiTrigger? { EmojiShortcodes.trigger(in: text, caret: caret) }
        var rows: [EmojiMatch] { trigger.map { EmojiShortcodes.matches($0, in: EmojiShortcodesTests.table, prefs: prefs, now: 1_000) } ?? [] }

        mutating func acceptFirst() {
            guard let trigger, let first = rows.first else { Issue.record("no rows for \(text)"); return }
            apply(EmojiShortcodes.accept(first, for: trigger, in: text, table: EmojiShortcodesTests.table, tone: prefs.tone))
        }
    }

    @Test func tableLoadsFromTheBundle() {
        #expect(Self.table.records.count > 1_500)
        #expect(Self.table.record(code: "pleading_face")?.emoji == "🥺")
        #expect(Self.table.record(code: "thumbsup")?.emoji == "👍")
        #expect(Self.table.record(code: "wave")?.tones.count == 5)
    }

    // 1. Trigger

    @Test func plead() {
        let typing = Typing("hi :plead")
        #expect(typing.trigger?.query == "plead")
        #expect(typing.rows.first?.emoji == "🥺")
        #expect(typing.rows.first?.code == "pleading_face")
    }

    @Test(arguments: ["meet 10:30", "see https://ex", "key:value", "`:sm", "foo:bar", "see https://x:8080",
                      "```\n:smile", ":s", "a :"])
    func noTrigger(_ text: String) {
        #expect(Typing(text).trigger == nil, "\(text)")
    }

    @Test(arguments: [":sm", "(:sm", "[:sm", "{:sm", "\":sm", "':sm", "line\n:sm", "a ```x``` :sm"])
    func triggersAtAWordStart(_ text: String) {
        #expect(Typing(text).trigger?.query == "sm", "\(text)")
    }

    @Test func triggerFollowsTheCaretNotTheEnd() {
        let text = "a :plead and more"
        let trigger = EmojiShortcodes.trigger(in: text, caret: 8)
        #expect(trigger?.query == "plead")
        #expect(trigger?.range == NSRange(location: 2, length: 6))
    }

    // 2. Rows

    @Test func fuzzySubsequenceListsThumbsUp() {
        #expect(Typing(":thup").rows.contains { $0.emoji == "👍" })
    }

    @Test func sobIsFirst() {
        #expect(Typing(":sob").rows.first?.emoji == "😭")
    }

    @Test func emoticonListsItsFace() {
        #expect(Typing(":)").rows.first?.emoji == "🙂")
        #expect(Typing("<3").rows.first?.emoji == "❤️")
        #expect(Typing(";)").rows.first?.emoji == "😉")
        #expect(Typing(":'(").rows.first?.emoji == "😢")
    }

    @Test func atMostSixRowsOneGlyphEach() {
        let rows = Typing(":sm").rows
        #expect(rows.count == 6)
        #expect(Set(rows.map(\.emoji)).count == rows.count)
    }

    @Test func wordOfTheCodeAndAlias() {
        // `face` is a word of `pleading_face` (and many more); `+1` is 👍's shown code, `thumbsup` its alias.
        #expect(Typing(":thumbsu").rows.first?.emoji == "👍")
        #expect(Typing(":thumbsu").rows.first?.code == "thumbsup")
    }

    @Test func recentRanksUpButNeverOverExact() {
        let plain = Typing(":smi").rows
        let late = plain.last!
        let recent = EmojiPrefs().recording(late.emoji, now: 1_000)
        let boosted = Typing(":smi", prefs: recent).rows
        #expect(boosted.firstIndex { $0.emoji == late.emoji }! < plain.count - 1)
        // `:smile` is exact for 😄: a recent 😃 never goes over it.
        let smiley = EmojiPrefs().recording("😃", now: 1_000).recording("😃", now: 1_000)
        #expect(Typing(":smile", prefs: smiley).rows.first?.emoji == "😄")
    }

    // 3. Accept

    @Test func acceptWritesTheGlyphAndOneSpace() {
        var typing = Typing("hi :plead")
        typing.acceptFirst()
        #expect(typing.text == "hi 🥺 ")
        #expect(typing.caret == typing.text.utf16.count)
    }

    @Test func acceptBeforeASpaceAddsNoneAndStepsOverIt() {
        var typing = Typing("hi :plead there")
        typing.caret = 9
        typing.acceptFirst()
        #expect(typing.text == "hi 🥺 there")
        #expect(typing.caret == ("hi 🥺 " as NSString).length)
    }

    // 4. Closing colon

    @Test func closingColonConverts() {
        var typing = Typing()
        typing.type(":pleading_face:")
        #expect(typing.text == "🥺")
        #expect(typing.caret == "🥺".utf16.count)
    }

    @Test func unknownCodeStays() {
        var typing = Typing()
        typing.type(":notacode:")
        #expect(typing.text == ":notacode:")
    }

    @Test func closingColonInCodeOrMidWordStays() {
        for text in ["`:tada:", "key:tada:", "```\n:tada:"] {
            var typing = Typing()
            typing.type(text)
            #expect(typing.text == text, "\(text)")
        }
    }

    @Test func closingColonIsCaseFoldedAndAfterAnOpener() {
        var typing = Typing()
        typing.type("(:TADA:")
        #expect(typing.text == "(🎉")
    }

    // 5. Skin tones

    @Test func slackToneSuffixWritesAndRemembersTheTone() {
        var typing = Typing()
        typing.type(":wave::skin-tone-4:")
        #expect(typing.text == "👋🏽")
        #expect(typing.prefs.tone == 3)
        typing.type(" :thumbsup:")
        #expect(typing.text == "👋🏽 👍🏽")
    }

    @Test func rememberedToneOnAcceptAndAnUntoneableStaysBase() {
        var typing = Typing("", prefs: EmojiPrefs(tone: 5))
        typing.type(":wave")
        typing.acceptFirst()
        #expect(typing.text == "👋🏿 ")
        typing.type(":tada:")
        #expect(typing.text == "👋🏿 🎉")
    }

    // 8. Paste

    @Test func pasteConvertsOutsideCode() {
        let pasted = EmojiShortcodes.convertingPaste("ship it :tada: `:tada:`", table: Self.table, tone: 0)
        #expect(pasted?.text == "ship it 🎉 `:tada:`")
    }

    @Test func pasteLeavesUnknownURLsMidWordAndFences() {
        #expect(EmojiShortcodes.convertingPaste(":notacode: key:tada: https://x.com/:tada:", table: Self.table, tone: 0) == nil)
        #expect(EmojiShortcodes.convertingPaste("```\n:tada:\n```\n:tada:", table: Self.table, tone: 0)?.text == "```\n:tada:\n```\n🎉")
        #expect(EmojiShortcodes.convertingPaste(":tada::tada: :wave::skin-tone-2:", table: Self.table, tone: 0)?.text == "🎉🎉 👋🏻")
        #expect(EmojiShortcodes.convertingPaste(":wave::skin-tone-2:", table: Self.table, tone: 0)?.rememberTone == 1)
    }

    // Frecency

    @Test func recentsKeepTheNewestFirstAndCap() {
        var prefs = EmojiPrefs()
        for index in 0..<40 { prefs = prefs.recording("e\(index)", now: Double(index)) }
        #expect(prefs.recents.count == EmojiPrefs.maxRecents)
        #expect(prefs.recents.first?.key == "e39")
    }
}
