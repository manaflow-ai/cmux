import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// Typing in a new tab's address bar before its page reports its first address. The focus can leave the field for a
/// moment while the tab is made (the daemon's tab takes the stand-in's place, a workspace is selected), and comes
/// back by the focus rules. The page's first address arrived in between and erased the text the person had typed
/// ("A navigation supersedes text left behind by an earlier blur"), so the field came back empty and Return did
/// nothing (Lawrence 2026-11-10: "I type in something and press Enter and if it's too early nothing happens").
/// A tab's first address is not a navigation the person made: the typed text stays.
@MainActor
struct OmnibarEarlyTypingTests {
    private let resolver = OmniboxResolver()
    private static let first = URL(string: "https://start.example/")

    private func reduce(_ inputs: [OmnibarInput], from state: OmnibarState = OmnibarState()) -> OmnibarState {
        inputs.reduce(state) { OmnibarReducer.reduce($0, $1, resolver: resolver).state }
    }

    private func typed(_ text: String) -> [OmnibarInput] {
        var current = ""
        return [.focusGained(.keyboard)] + text.map { character in
            current.append(character)
            return .fieldChanged(.init(text: current, selection: NSRange(location: current.utf16.count, length: 0)), .insert)
        }
    }

    @Test func textTypedBeforeTheFirstAddressSurvivesAShortBlur() {
        let state = reduce(typed("git") + [.focusLost, .pageURLChanged(Self.first), .focusGained(.programmatic)])
        #expect(state.phase == .editing, "the field came back without the typed text: \(state.phase)")
        #expect(state.fieldText == "git", "the typed text was erased by the tab's first address: \(state.fieldText)")
        #expect(state.pageURL == Self.first)
    }

    /// The same order with the field still focused already kept the text; pinned here.
    @Test func textTypedBeforeTheFirstAddressSurvivesWhileFocused() {
        let state = reduce(typed("git") + [.pageURLChanged(Self.first)])
        #expect(state.fieldText == "git")
    }

    /// A later navigation of the page (the person clicked a link after leaving the field) still supersedes the text.
    @Test func aLaterNavigationStillSupersedesLeftText() {
        let loaded = reduce([.pageURLChanged(Self.first)])
        let state = reduce(typed("git") + [.focusLost, .pageURLChanged(URL(string: "https://start.example/next")), .focusGained(.programmatic)], from: loaded)
        #expect(state.phase == .focused)
        #expect(state.retainedText == nil)
    }
}
