import CMUXMobileCore
public import CmuxMobileShellModel
import Foundation

extension MobileShellComposite {
    /// Connect using the current pairing input, accepting either a code or pairing URL.
    @discardableResult
    public func connectPairingInput() async -> MobilePairingURLConnectionResult {
        let trimmedCode = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else {
            return .failed
        }
        if CmxPairingURLScheme.hasPairingScheme(trimmedCode) {
            return await connectPairingURLResult(trimmedCode)
        }
        connectPreviewHost()
        return connectionState == .connected ? .connected : .failed
    }

    /// Connect to a manually-entered Mac host and optionally associate the
    /// resulting session with an existing paired-Mac device id.
    @discardableResult
    public func connectManualHost(
        name: String,
        host: String,
        port: Int,
        pairedMacDeviceID: String? = nil
    ) async -> MobilePairingURLConnectionResult {
        await connectManualHost(
            name: name,
            host: host,
            port: port,
            pairedMacDeviceID: pairedMacDeviceID,
            recordsPairingAttempt: true
        )
    }
}
