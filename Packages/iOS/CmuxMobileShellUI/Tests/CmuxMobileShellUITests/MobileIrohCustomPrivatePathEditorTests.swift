#if os(iOS)
import CMUXMobileCore
import Testing
@testable import CmuxMobileShellUI

@Test @MainActor
func customPrivatePathEditorValidationUsesSharedAddressLimit() {
    let addresses = (1 ... CmxIrohCustomPrivatePathDraft.maximumAddressCount)
        .map { "10.0.0.\($0)" }
    let valid = MobileIrohCustomPrivatePathEditor.validate(
        addressesText: addresses.joined(separator: "\n"),
        selectedMacDeviceID: "123e4567-e89b-42d3-a456-426614174004"
    )
    #expect(valid.canSave)
    #expect(valid.addresses == addresses)

    let tooMany = MobileIrohCustomPrivatePathEditor.validate(
        addressesText: (addresses + ["10.0.0.9"]).joined(separator: "\n"),
        selectedMacDeviceID: "123e4567-e89b-42d3-a456-426614174004"
    )
    #expect(!tooMany.canSave)

    let noMac = MobileIrohCustomPrivatePathEditor.validate(
        addressesText: "10.0.0.1",
        selectedMacDeviceID: ""
    )
    #expect(!noMac.canSave)
}
#endif
