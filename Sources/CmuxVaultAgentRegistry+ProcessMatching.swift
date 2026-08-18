import CmuxCore

struct CmuxVaultAgentProcessMatchDiagnostic: Sendable {
    let registration: CmuxVaultAgentRegistration?
    let manifestEntry: CmuxAgentManifestEntry?
    let manifestResult: CmuxAgentDetectionResult?
}

extension CmuxVaultAgentRegistry {
    /// Returns the most specific registration matching a live process.
    ///
    /// Project configuration outranks the manifest catalog. The catalog then
    /// applies its own user-before-bundled order, followed by compiled
    /// compatibility registrations when no manifest identified the process.
    func matchingRegistration(for process: VaultObservedAgentProcess) -> CmuxVaultAgentRegistration? {
        for registration in registrations.reversed()
        where projectConfiguredIDs.contains(registration.id) {
            if registration.detect.matches(process) {
                return registration
            }
        }

        if let match = manifestEngine?.matchingEntry(
            for: CmuxAgentProcessSnapshot(process)
        ) {
            return registration(id: match.entry.manifest.id)
        }

        for registration in registrations.reversed()
        where !projectConfiguredIDs.contains(registration.id)
            && !manifestBackedIDs.contains(registration.id) {
            if registration.detect.matches(process) {
                return registration
            }
        }
        return nil
    }

    /// Returns the selected registration and the exact manifest result, when
    /// selection came from the data-driven catalog.
    func matchingRegistrationDiagnostic(
        for process: VaultObservedAgentProcess,
        screen: String = "",
        osc: String = ""
    ) -> CmuxVaultAgentProcessMatchDiagnostic {
        for registration in registrations.reversed()
        where projectConfiguredIDs.contains(registration.id) {
            if registration.detect.matches(process) {
                return CmuxVaultAgentProcessMatchDiagnostic(
                    registration: registration,
                    manifestEntry: nil,
                    manifestResult: nil
                )
            }
        }

        if let result = manifestDetection(process: process, screen: screen, osc: osc),
           let agentID = result.agentID {
            return CmuxVaultAgentProcessMatchDiagnostic(
                registration: registration(id: agentID),
                manifestEntry: manifestEntry(id: agentID),
                manifestResult: result
            )
        }

        for registration in registrations.reversed()
        where !projectConfiguredIDs.contains(registration.id)
            && !manifestBackedIDs.contains(registration.id) {
            if registration.detect.matches(process) {
                return CmuxVaultAgentProcessMatchDiagnostic(
                    registration: registration,
                    manifestEntry: nil,
                    manifestResult: nil
                )
            }
        }
        return CmuxVaultAgentProcessMatchDiagnostic(
            registration: nil,
            manifestEntry: nil,
            manifestResult: nil
        )
    }
}
