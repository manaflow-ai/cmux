import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// The literals the app builds without a trap (crash program P1b): each one
/// parses, so the non-trapping fallbacks are never taken.
@MainActor
struct StaticURLTests {
    @Test(arguments: StaticURL.allCases)
    func everyLiteralParses(_ link: StaticURL) throws {
        let parsed = try #require(URL(string: link.rawValue))
        #expect(link.url == parsed)
        #expect(link.url.absoluteString == link.rawValue)
    }
}

@MainActor
struct FunctionKeyCharacterTests {
    nonisolated static let codes = [NSLeftArrowFunctionKey, NSRightArrowFunctionKey, NSUpArrowFunctionKey, NSDownArrowFunctionKey,
                        NSPageUpFunctionKey, NSPageDownFunctionKey, NSHomeFunctionKey, NSEndFunctionKey, NSDeleteFunctionKey]

    @Test(arguments: codes)
    func everyFunctionKeyIsOneScalar(_ code: Int) {
        #expect(FunctionKeyCharacter.string(code).unicodeScalars.map(\.value) == [UInt32(code)])
    }

    @Test func arrowKeysMatchTheShortcutConstants() {
        #expect(FunctionKeyCharacter.string(NSLeftArrowFunctionKey) == Shortcut.leftArrowKey)
        #expect(FunctionKeyCharacter.string(NSRightArrowFunctionKey) == Shortcut.rightArrowKey)
        #expect(FunctionKeyCharacter.string(NSUpArrowFunctionKey) == Shortcut.upArrowKey)
        #expect(FunctionKeyCharacter.string(NSDownArrowFunctionKey) == Shortcut.downArrowKey)
    }

    @Test func aCodeOutsideUnicodeGivesEmpty() {
        #expect(FunctionKeyCharacter.string(-1) == "")
        #expect(FunctionKeyCharacter.string(0xD800) == "")
    }
}
