import CmuxSimulator

@MainActor
enum SimulatorAttachmentReadiness {
    static func begin(
        baselineCapabilities: Set<SimulatorCapability>,
        send: (SimulatorWorkerOutbound) -> Void,
        hydrate: @escaping @MainActor () async -> Set<SimulatorCapability>,
        applyHydratedCapabilities: @escaping @MainActor (Set<SimulatorCapability>) -> Void
    ) -> Task<Void, Never> {
        send(.capabilities(baselineCapabilities))
        send(.status(.streaming))

        return Task { @MainActor in
            guard !Task.isCancelled else { return }
            let hydratedCapabilities = await hydrate()
            guard !Task.isCancelled else { return }
            applyHydratedCapabilities(hydratedCapabilities)
        }
    }
}
