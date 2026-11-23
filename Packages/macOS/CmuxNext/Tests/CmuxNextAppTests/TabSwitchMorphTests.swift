import AppKit
import Testing
import CmuxNextPages

@MainActor
struct TabSwitchMorphTests {
    private let light = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    private let dark = CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)

    @Test func theMorphIsOffByDefault() {
        #expect(!TabSwitchMorph.isOn)
    }

    @Test func aGroundThatChangedEases() {
        #expect(TabSwitchMorph.eases(from: light, to: dark))
        #expect(TabSwitchMorph.eases(from: dark, to: light))
    }

    @Test func noChangeOrAnUnknownGroundEasesNothing() {
        #expect(!TabSwitchMorph.eases(from: light, to: light))
        #expect(!TabSwitchMorph.eases(from: light, to: nil))
        #expect(!TabSwitchMorph.eases(from: nil, to: dark))
    }

    @Test func runningItAddsAFadeOnlyForAChangedGround() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        host.wantsLayer = true
        TabSwitchMorph.run(on: host, from: light, to: light, in: nil)
        #expect(host.layer?.animationKeys()?.isEmpty ?? true)
    }
}
