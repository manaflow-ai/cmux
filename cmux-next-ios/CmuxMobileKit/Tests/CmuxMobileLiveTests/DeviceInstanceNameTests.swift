import Foundation
import Testing
@testable import CmuxMobileLive

/// Each cmux build on a phone names itself apart on the account: the App Store build by the
/// phone's name alone, every other build with its label (Aziz, 2026-11-12: "INTERNAL vs App
/// Store [app store should be naked with no decoration in its display name] vs BETA").
@Suite struct DeviceInstanceNameTests {
    @Test func theAppStoreBuildIsTheBarePhoneName() {
        #expect(DeviceInstanceName(device: "Aziz's iPhone", label: "").value == "Aziz's iPhone")
        #expect(DeviceInstanceName(device: "Aziz's iPhone", label: nil).value == "Aziz's iPhone")
        #expect(DeviceInstanceName(device: "Aziz's iPhone", label: "  ").value == "Aziz's iPhone")
    }

    @Test func everyOtherBuildAddsItsLabel() {
        #expect(DeviceInstanceName(device: "Aziz's iPhone", label: "INTERNAL").value == "Aziz's iPhone (INTERNAL)")
        #expect(DeviceInstanceName(device: "Aziz's iPhone", label: "BETA").value == "Aziz's iPhone (BETA)")
        #expect(DeviceInstanceName(device: "Aziz's iPhone", label: "DEV my-tag").value == "Aziz's iPhone (DEV my-tag)")
    }

    @Test func twoBuildsOnOnePhoneReadApart() {
        let store = DeviceInstanceName(device: "iPhone", label: "")
        let internal = DeviceInstanceName(device: "iPhone", label: "INTERNAL")
        #expect(store.value != internal.value)
    }

    @Test func aBlankPhoneNameFallsBackToTheLabel() {
        #expect(DeviceInstanceName(device: " ", label: "INTERNAL").value == "INTERNAL")
    }

    /// The label comes from the running build's Info.plist key; a bundle without it is unlabeled.
    @Test func aBundleWithoutTheKeyIsUnlabeled() {
        #expect(DeviceInstanceName(device: "iPhone", bundle: Bundle(for: Marker.self)).label == nil)
    }

    private final class Marker {}
}
