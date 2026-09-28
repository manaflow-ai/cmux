import CMUXMobileCore
import CmuxMobileRPC
import Foundation

/// Phone half of `mobile.terminal.view_set`: which Mac client last received
/// which set of rendered terminals, and the single in-flight declaration.
struct MobileTerminalViewSetSync {
    var acknowledgedSurfaceIDs: Set<String>?
    var acknowledgedClient: ObjectIdentifier?
    var inFlight: Task<Void, Never>?
    var needsResend = false
}

extension MobileShellComposite {
    /// The terminals this device renders: every mounted output sink. The Mac
    /// captures and sends render grids for these only.
    var renderedTerminalSurfaceIDs: Set<String> {
        Set(terminalByteContinuationsBySurfaceID.keys.filter { UUID(uuidString: $0) != nil })
    }

    /// Declares ``renderedTerminalSurfaceIDs`` to the foreground Mac when it
    /// changed since the Mac's last acknowledgement. `force` resends anyway,
    /// for a fresh or re-asserted event subscription.
    ///
    /// One declaration is in flight at a time; a change during the flight
    /// sends the then-current set afterwards, so the Mac always converges on
    /// the latest set. A failed declaration forgets the acknowledgement, so
    /// the next change or re-subscribe sends again.
    func syncTerminalViewSet(force: Bool = false) {
        guard let client = remoteClient,
              supportedHostCapabilities.contains(MobileTerminalViewSetRPC.capability) else {
            return
        }
        if force {
            terminalViewSetSync.acknowledgedSurfaceIDs = nil
        }
        guard terminalViewSetSync.inFlight == nil else {
            terminalViewSetSync.needsResend = true
            return
        }
        let surfaceIDs = renderedTerminalSurfaceIDs
        if terminalViewSetSync.acknowledgedClient == ObjectIdentifier(client),
           terminalViewSetSync.acknowledgedSurfaceIDs == surfaceIDs {
            return
        }
        terminalViewSetSync.needsResend = false
        terminalViewSetSync.inFlight = Task { [weak self] in
            let accepted: Bool
            do {
                let request = try MobileCoreRPCClient.requestData(
                    method: MobileTerminalViewSetRPC.method,
                    params: MobileTerminalViewSetRPC.params(surfaceIDs: surfaceIDs)
                )
                // Bounded so a wedged connection cannot hold the single
                // in-flight slot; the re-subscribe that follows recovery
                // declares again.
                _ = try await client.sendRequest(request, timeoutNanoseconds: 10_000_000_000)
                accepted = true
            } catch {
                accepted = false
            }
            guard let self else { return }
            self.terminalViewSetSync.inFlight = nil
            if accepted, self.remoteClient === client {
                self.terminalViewSetSync.acknowledgedClient = ObjectIdentifier(client)
                self.terminalViewSetSync.acknowledgedSurfaceIDs = surfaceIDs
            } else {
                self.terminalViewSetSync.acknowledgedSurfaceIDs = nil
            }
            if self.terminalViewSetSync.needsResend {
                self.syncTerminalViewSet()
            }
        }
    }
}
