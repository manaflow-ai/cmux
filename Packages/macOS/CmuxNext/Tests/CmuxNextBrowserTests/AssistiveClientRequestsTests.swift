import CmuxNextBrowser
import Foundation
import Testing

/// What assistive clients ask of the app: VoiceOver sets `AXEnhancedUserInterface`, automation
/// drivers (cua, Electron-style tooling) `AXManualAccessibility`. The app wants Chromium's page
/// accessibility while either is on, and reads back what was set.
@Suite struct AssistiveClientRequestsTests {
    @Test func eitherAttributeTurnsAccessibilityOn() {
        for attribute in ["AXEnhancedUserInterface", "AXManualAccessibility"] {
            var requests = AssistiveClientRequests()
            #expect(!requests.wantsAccessibility)
            let changed = requests.set(NSNumber(value: true), for: attribute)
            #expect(changed)
            #expect(requests.wantsAccessibility)
            #expect(requests.value(for: attribute) == true)
        }
    }

    @Test func itStaysOnUntilEveryClientTurnsItOff() {
        var requests = AssistiveClientRequests()
        _ = requests.set(true, for: "AXEnhancedUserInterface")
        _ = requests.set(NSNumber(value: 1), for: "AXManualAccessibility")
        _ = requests.set(false, for: "AXManualAccessibility")
        #expect(requests.wantsAccessibility)
        _ = requests.set(NSNumber(value: false), for: "AXEnhancedUserInterface")
        #expect(!requests.wantsAccessibility)
        #expect(requests.value(for: "AXManualAccessibility") == false)
    }

    @Test func otherAttributesAreNotAssistiveClientRequests() {
        var requests = AssistiveClientRequests()
        let changed = requests.set(true, for: "AXFocused")
        #expect(!changed)
        #expect(requests.value(for: "AXFocused") == nil)
        #expect(!requests.wantsAccessibility)
    }

    @Test func theLaunchSwitchKeepsItOnWhateverClientsSet() {
        var requests = AssistiveClientRequests(environment: ["CMUX_NEXT_ACCESSIBILITY": "1"])
        #expect(requests.wantsAccessibility)
        _ = requests.set(false, for: "AXManualAccessibility")
        #expect(requests.wantsAccessibility)
        #expect(requests.value(for: "AXManualAccessibility") == false)
        for off in [[:], ["CMUX_NEXT_ACCESSIBILITY": "0"], ["CMUX_NEXT_ACCESSIBILITY": ""]] {
            #expect(!AssistiveClientRequests(environment: off).wantsAccessibility)
        }
    }
}
