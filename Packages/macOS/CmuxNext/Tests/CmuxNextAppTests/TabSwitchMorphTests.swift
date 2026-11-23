import AppKit
import Testing
@testable import CmuxNextApp

@MainActor
struct TabSwitchMorphTests {
    private let light = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    private let dark = CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)

    @Test func theMorphIsOffByDefault() {
        #expect(!TabSwitchMorph.isOn)
    }

    @Test func aGroundThatChangedEasesFromTheOldToTheNew() throws {
        let animation = try #require(TabSwitchMorph.animation(from: light, to: dark, duration: 0.2))
        #expect(animation.keyPath == "backgroundColor")
        #expect(animation.fromValue as! CGColor == light)
        #expect(animation.toValue as! CGColor == dark)
        #expect(animation.duration == 0.2)
    }

    @Test func noChangeNoGroundOrNoTimeEasesNothing() {
        #expect(TabSwitchMorph.animation(from: light, to: light, duration: 0.2) == nil)
        #expect(TabSwitchMorph.animation(from: light, to: nil, duration: 0.2) == nil)
        #expect(TabSwitchMorph.animation(from: light, to: dark, duration: 0) == nil)
    }
}
