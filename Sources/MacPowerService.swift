import Foundation

@MainActor
final class MacPowerService {
    enum ServiceError: Error, Equatable { case assertionFailed, lowPowerMutationFailed }

    private let powerControls: any SleepyPowerControlling
    private let assertionHolder: any PowerAssertionHolding

    init(
        powerControls: any SleepyPowerControlling = SleepyPowerControls(),
        assertionHolder: any PowerAssertionHolding = PowerAssertionHolder()
    ) {
        self.powerControls = powerControls
        self.assertionHolder = assertionHolder
    }

    func status() async -> MacPowerStatus {
        MacPowerStatus(
            keepAwakeEnabled: assertionHolder.isEnabled,
            lowPowerEnabled: await powerControls.isLowPowerOn()
        )
    }

    func sleepDisplay() async { await powerControls.sleepDisplayNow() }

    func setKeepAwake(_ enabled: Bool) async throws -> MacPowerStatus {
        do { try assertionHolder.setEnabled(enabled) }
        catch { throw ServiceError.assertionFailed }
        return await status()
    }

    func setLowPowerMode(_ enabled: Bool) async throws -> MacPowerStatus {
        let applied = await powerControls.setLowPowerMode(enabled)
        guard applied == enabled else { throw ServiceError.lowPowerMutationFailed }
        let authoritative = await status()
        guard authoritative.lowPowerEnabled == enabled else {
            throw ServiceError.lowPowerMutationFailed
        }
        return authoritative
    }
}
