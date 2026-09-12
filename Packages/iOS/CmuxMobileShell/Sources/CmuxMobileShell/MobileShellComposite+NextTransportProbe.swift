#if DEBUG
import CmuxMobileRPC
import Foundation

extension MobileShellComposite {
    /// Probes only after the authenticated connection passes all readiness gates.
    func probeNextTransportBootstrapIfNeeded() {
        // Graduation bootstrap probe runs over THIS composite's live RPC client
        // after a connection turns healthy. It is owned by the connection
        // generation and cancelled when that client is replaced.
        if let probe = nextTransportBootstrapProbe,
            let client = remoteClient,
            let macDeviceID = activeTicket?.macDeviceID,
            !macDeviceID.isEmpty,
            !Self.isSyntheticManualDeviceID(macDeviceID)
        {
            let generation = connectionGeneration
            if nextTransportBootstrapProbeGeneration != generation {
                nextTransportBootstrapProbeGeneration = generation
                nextTransportBootstrapProbeTask = Task { [weak self] in
                    await probe(client, macDeviceID, generation)
                    guard !Task.isCancelled else { return }
                    guard let self,
                        self.connectionGeneration == generation,
                        self.remoteClient === client
                    else { return }
                    self.nextTransportBootstrapProbeTask = nil
                }
            }
        }
    }
}
#endif
