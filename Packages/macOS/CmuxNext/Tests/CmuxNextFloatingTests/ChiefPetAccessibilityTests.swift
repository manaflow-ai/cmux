import AppKit
@testable import CmuxNextFloating
import Foundation
import Testing

/// The Chief pet with VoiceOver: the panel never takes the keys, so a press through accessibility
/// is the only way in that is not the pointer. The character is a button that opens the reply box,
/// and a notice is a button that opens its tab, the same targets a click has.
@MainActor @Suite(.serialized) struct ChiefPetAccessibilityTests {
    static func defaults() -> UserDefaults {
        let name = "ChiefPetAccessibilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    static func notice(_ id: UInt64, _ title: String) -> ChiefPetNotice {
        ChiefPetNotice(id: id, tab: "tab-\(id)", surface: nil, title: title, detail: "detail \(id)", kind: .needsYou)
    }

    /// The shown views under `view` that VoiceOver reads as elements (an element's own children are its own).
    static func elements(in view: NSView) -> [NSView] {
        view.subviews.filter { !$0.isHidden }.flatMap { $0.isAccessibilityElement() ? [$0] : elements(in: $0) }
    }

    @Test func theCharacterIsAButtonThatOpensTheReplyBox() throws {
        let panel = ChiefPetPanel(defaults: Self.defaults())
        var clicks = 0
        panel.onClick = { clicks += 1 }
        let character = try #require(Self.elements(in: panel.pet).first { $0.accessibilityLabel() == ChiefPetStrings.accessibilityLabel })
        #expect(character.accessibilityRole() == .button)
        #expect(character.accessibilityPerformPress())
        #expect(clicks == 1)
    }

    @Test func aFoldedDeckReadsAsItsFrontNoticeAndPressingItOpensIt() throws {
        let bubble = ChiefPetBubbleView(frame: NSRect(x: 0, y: 0, width: ChiefPetBubblePanel.width, height: 80))
        var opened: [Int] = []
        bubble.onOpen = { opened.append($0) }
        bubble.show([Self.notice(3, "Newest"), Self.notice(2, "Middle"), Self.notice(1, "Oldest")], expanded: false)
        let elements = Self.elements(in: bubble)
        // Folded, only the front capsule shows its text and takes a click; the deck behind it is a picture.
        #expect(elements.count == 1)
        let front = try #require(elements.first)
        #expect(front.accessibilityRole() == .button)
        #expect(front.accessibilityLabel() == "Newest. detail 3")
        #expect(front.accessibilityPerformPress())
        #expect(opened == [0])
    }

    @Test func anUnfoldedColumnReadsEveryNoticeAndEachOpensItsOwn() throws {
        let bubble = ChiefPetBubbleView(frame: NSRect(x: 0, y: 0, width: ChiefPetBubblePanel.width, height: 200))
        var opened: [Int] = []
        bubble.onOpen = { opened.append($0) }
        bubble.show([Self.notice(3, "Newest"), Self.notice(2, "Middle"), Self.notice(1, "Oldest")], expanded: true)
        let elements = Self.elements(in: bubble)
        #expect(elements.count == 3)
        let middle = try #require(elements.first { $0.accessibilityLabel() == "Middle. detail 2" })
        #expect(middle.accessibilityPerformPress())
        #expect(opened == [1])
        // Folded again, the capsules behind the front one stop being elements.
        bubble.show([Self.notice(3, "Newest"), Self.notice(2, "Middle"), Self.notice(1, "Oldest")], expanded: false)
        #expect(Self.elements(in: bubble).count == 1)
    }
}
