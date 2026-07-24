import Carbon.HIToolbox
import Testing
@testable import CmuxTerminal

@Suite struct TerminalKeyInputPlannerTests {
    private let planner = TerminalKeyInputPlanner()

    @Test func translatedOptionInputUsesTranslatedText() {
        let actions = planner.actions(for: snapshot(translatedText: "n"))

        #expect(actions == [.sendKey(text: "n", composing: false)])
    }

    @Test func textInputConsumptionConsumesPhysicalKey() {
        let plan = planner.plan(for: snapshot(
            textInputConsumed: true,
            translatedText: " "
        ))

        #expect(plan.actions.isEmpty)
        #expect(!plan.forwardsPhysicalKey)
    }

    @Test func activeCompositionKeepsTranslatedKeyComposing() {
        let plan = planner.plan(for: snapshot(
            hasMarkedText: true,
            translatedText: "ᄒ"
        ))

        #expect(plan.actions == [.sendKey(text: "ᄒ", composing: true)])
        #expect(!plan.forwardsPhysicalKey)
    }

    @Test func textInputCommandForwardsPhysicalKey() {
        let plan = planner.plan(for: snapshot(
            textInputConsumed: true,
            textInputCommandPerformed: true,
            translatedText: "\r"
        ))

        #expect(plan.actions == [.sendKey(text: nil, composing: false)])
        #expect(plan.forwardsPhysicalKey)
    }

    @Test func committedTextDoesNotOwnNativeKeyRelease() {
        let plan = planner.plan(for: snapshot(
            hadMarkedText: true,
            textInputConsumed: true,
            committedText: ["日本"],
            translatedText: nil
        ))

        #expect(plan.actions == [.sendCommittedText("日本")])
        #expect(!plan.forwardsPhysicalKey)
    }

    @Test func committedPreeditTextAndCommandRemainOrdered() {
        let actions = planner.actions(for: snapshot(
            hadMarkedText: true,
            textInputCommandPerformed: true,
            committedText: ["한"],
            translatedText: nil
        ))

        #expect(actions == [
            .sendCommittedText("한"),
            .sendKey(text: nil, composing: false),
        ])
    }

    @Test func committedTextWithoutPriorPreeditUsesPhysicalKey() {
        let actions = planner.actions(for: snapshot(
            committedText: ["你"],
            translatedText: nil
        ))

        #expect(actions == [.sendKey(text: "你", composing: false)])
    }

    @Test(arguments: [
        ("Korean", "한"),
        ("Simplified Chinese", "你"),
        ("Traditional Chinese", "臺"),
        ("Japanese", "日本"),
        ("Russian", "ф"),
        ("Dvorak", "o"),
        ("Arabic", "ع"),
        ("Hebrew", "ש"),
        ("Devanagari", "क"),
        ("Thai", "ก"),
        ("Vietnamese decomposed", "a\u{301}"),
        ("emoji grapheme", "👨🏽‍💻"),
    ])
    func directLayoutTextRemainsUnchanged(
        _ inputSource: String,
        text: String
    ) {
        let actions = planner.actions(for: snapshot(translatedText: text))

        #expect(actions == [.sendKey(text: text, composing: false)])
    }

    @Test(arguments: [
        ("Korean", "한"),
        ("Simplified Chinese", "你"),
        ("Traditional Chinese", "臺"),
        ("Japanese", "日本"),
        ("Vietnamese decomposed", "a\u{301}"),
        ("emoji grapheme", "👨🏽‍💻"),
    ])
    func committedPreeditTextRemainsUnchanged(
        _ inputMethod: String,
        text: String
    ) {
        let actions = planner.actions(for: snapshot(
            hadMarkedText: true,
            committedText: [text],
            translatedText: nil
        ))

        #expect(actions == [.sendCommittedText(text)])
    }

    @Test func allInstalledStaticKeyboardLayoutsPassTextUnchanged() throws {
        let properties = [
            kTISPropertyInputSourceType: kTISTypeKeyboardLayout,
        ] as CFDictionary
        let sources = try #require(
            TISCreateInputSourceList(properties, true)?.takeRetainedValue()
                as? [TISInputSource]
        )
        let modifierBits = [shiftKey, optionKey, controlKey, cmdKey]
        let modifierStates = (0..<(1 << modifierBits.count)).map { mask in
            modifierBits.enumerated().reduce(0) { result, entry in
                mask & (1 << entry.offset) == 0
                    ? result
                    : result | entry.element
            }
        }
        var checkedLayouts = 0
        var checkedTranslations = 0
        var mismatches: [String] = []

        for source in sources {
            guard let layoutDataPointer = TISGetInputSourceProperty(
                source,
                kTISPropertyUnicodeKeyLayoutData
            ) else {
                continue
            }
            let layoutData = Unmanaged<CFData>
                .fromOpaque(layoutDataPointer)
                .takeUnretainedValue()
            guard let bytes = CFDataGetBytePtr(layoutData) else { continue }
            let keyboardLayout = UnsafeRawPointer(bytes)
                .assumingMemoryBound(to: UCKeyboardLayout.self)
            checkedLayouts += 1

            for keyCode in UInt16(0)..<UInt16(128) {
                for modifierState in modifierStates {
                    guard let text = translatedText(
                        keyboardLayout: keyboardLayout,
                        keyCode: keyCode,
                        carbonModifiers: modifierState
                    ) else {
                        continue
                    }
                    checkedTranslations += 1
                    let actions = planner.actions(for: snapshot(
                        translatedText: text
                    ))
                    if actions != [.sendKey(text: text, composing: false)],
                       mismatches.count < 10 {
                        mismatches.append(
                            "\(inputSourceID(source)) keyCode=\(keyCode) modifiers=\(modifierState)"
                        )
                    }
                }
            }
        }

        #expect(checkedLayouts > 0)
        #expect(checkedTranslations > 0)
        #expect(mismatches.isEmpty)
    }

    // Ported from Ghostty's SurfaceViewAppKitTests.
    @Test(arguments: [
        ("\u{0008}", true),
        ("\u{001F}", true),
        ("\u{007F}", false),
        (" ", false),
        ("h", false),
        ("", false),
        ("\u{0009}x", false),
        ("\u{0009}\u{0009}", false),
    ])
    func suppressesOnlySingleC0ControlTextWhileComposing(
        text: String,
        expected: Bool
    ) {
        let actions = planner.actions(for: snapshot(
            hasMarkedText: true,
            translatedText: "translated",
            rawText: text
        ))

        #expect(actions.isEmpty == expected)
    }

    // Ported from Ghostty's SurfaceViewAppKitTests.
    @Test func doesNotSuppressControlTextWhenNotComposing() {
        let actions = planner.actions(for: snapshot(
            translatedText: "translated",
            rawText: "\u{0008}"
        ))

        #expect(actions == [.sendKey(text: "translated", composing: false)])
    }

    // Ported from Ghostty's SurfaceViewAppKitTests.
    @Test func doesNotSuppressMissingText() {
        let actions = planner.actions(for: snapshot(
            hasMarkedText: true,
            translatedText: nil
        ))

        #expect(actions == [.sendKey(text: nil, composing: true)])
    }

    private func translatedText(
        keyboardLayout: UnsafePointer<UCKeyboardLayout>,
        keyCode: UInt16,
        carbonModifiers: Int
    ) -> String? {
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 16)
        var length = 0
        let status = UCKeyTranslate(
            keyboardLayout,
            keyCode,
            UInt16(kUCKeyActionDisplay),
            UInt32((carbonModifiers >> 8) & 0xFF),
            UInt32(LMGetKbdType()),
            UInt32(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }

    private func inputSourceID(_ source: TISInputSource) -> String {
        guard let pointer = TISGetInputSourceProperty(
            source,
            kTISPropertyInputSourceID
        ) else {
            return "unknown"
        }
        return Unmanaged<CFString>
            .fromOpaque(pointer)
            .takeUnretainedValue() as String
    }

    private func snapshot(
        hadMarkedText: Bool = false,
        hasMarkedText: Bool = false,
        textInputConsumed: Bool = false,
        textInputCommandPerformed: Bool = false,
        committedText: [String] = [],
        translatedText: String?,
        rawText: String? = nil
    ) -> TerminalKeyInputSnapshot {
        TerminalKeyInputSnapshot(
            hadMarkedText: hadMarkedText,
            hasMarkedText: hasMarkedText,
            textInputConsumed: textInputConsumed,
            textInputCommandPerformed: textInputCommandPerformed,
            committedText: committedText,
            event: TerminalKeyInputEvent(
                translatedText: translatedText,
                rawText: rawText ?? translatedText
            )
        )
    }
}
