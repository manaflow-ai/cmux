import CMUXMobileCore
import CmuxMobilePairedMac

@MainActor
extension MobileShellComposite {
    func connectStoredMacHost(
        name: String,
        host: String,
        port: Int,
        pairedMacDeviceID: String,
        instanceTag: String? = nil,
        persistsPairedMac: Bool = true,
        ifStillCurrent: (() -> Bool)? = nil
    ) async {
        await connectManualHost(
            name: name,
            host: host,
            port: port,
            pairedMacDeviceID: pairedMacDeviceID,
            instanceTagExpectation: MobileMacInstanceTagAuthority.expectation(
                storedInstanceTag: instanceTag
            ),
            recordsPairingAttempt: false,
            clearsForgottenMac: false,
            persistsPairedMac: persistsPairedMac,
            ifStillCurrent: ifStillCurrent
        )
    }

}
