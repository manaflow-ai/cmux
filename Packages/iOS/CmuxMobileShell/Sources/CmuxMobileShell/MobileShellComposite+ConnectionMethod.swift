import CmuxMobileShellModel

@MainActor
extension MobileShellComposite {
    /// Observes the shared Settings/onboarding choice and replaces any live
    /// foreground connection whose route was selected under the old method.
    func startObservingConnectionMethodChanges() {
        guard connectionMethodObservationTask == nil,
              let connectionMethodStore else { return }
        let initialMethod = connectionMethodStore.method
        connectionMethodObservationTask = Task { @MainActor [weak self, connectionMethodStore] in
            var observedMethod = initialMethod
            for await method in connectionMethodStore.changes() {
                guard let self, !Task.isCancelled else { return }
                guard method != observedMethod else { continue }
                observedMethod = method
                // A staged Tailscale selection is committed only after the
                // scanner connected that exact authorized route. The live
                // transport already satisfies the new strict policy, so keep
                // it instead of tearing it down and immediately redialing it.
                if method == .tailscale, self.activeRoute?.kind == .tailscale {
                    continue
                }
                self.recoverMobileConnection(trigger: .connectionMethodChanged)
            }
        }
    }
}
