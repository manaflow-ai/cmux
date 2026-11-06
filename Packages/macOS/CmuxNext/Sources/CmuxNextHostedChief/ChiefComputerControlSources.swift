public import CmuxNextHomeEngine

/// The two kinds of control source the profile's Computer tab reads (Chief computer take-over); the
/// App picks one per Chief (`AppServices.chiefComputerControlSource(agent:machine:)`).
extension HomeChiefComputerControlSource {
    /// A Cloud Chief's own sandbox, whose lease the Worker owns. The lease is read when the tab starts
    /// observing, after each of the person's gestures, and whenever the tab's own status read (every
    /// few seconds while it shows, ``ChiefComputerControlClient/feeding(_:into:)``) brings it back:
    /// no read of its own.
    @MainActor
    public static func sandbox(agent: String, store: ChiefComputerControlStore, client: ChiefComputerControlClient) -> HomeChiefComputerControlSource {
        let key = ChiefComputerControlStore.Key.agent(agent)
        func change(_ action: ChiefComputerControlClient.ControlAction) async throws {
            do {
                let state = try await client.control(agent: agent, action)
                store.apply(agent: agent, state: state, entitled: nil)
            } catch {
                store.refresh(agent: agent, client: client)
                throw error
            }
        }
        return HomeChiefComputerControlSource(
            state: { store.state(key) },
            observe: { onChange in
                let token = store.observe(key, onChange)
                store.refresh(agent: agent, client: client)
                return token
            },
            takeOver: { try await change(.takeOver) },
            handBack: { try await change(.handBack) },
            send: { input in
                do {
                    if let state = try await client.input(agent: agent, input) { store.apply(agent: agent, state: state, entitled: nil) }
                } catch let failure as ChiefComputerControlClient.Failure where failure.isNotHuman {
                    // The Chief has it again: the tab learns so at once, not at the next status read.
                    store.refresh(agent: agent, client: client)
                    throw failure
                }
            }
        )
    }

    /// A Cloud machine attached to a Chief on this Mac, whose lease `store` owns. The person's input
    /// goes through the machine's interactive desktop (`openInteractive`), not `send`.
    @MainActor
    public static func machine(_ machine: String, store: ChiefComputerControlStore, openInteractive: @escaping () -> Void) -> HomeChiefComputerControlSource {
        let key = ChiefComputerControlStore.Key.machine(machine)
        return HomeChiefComputerControlSource(
            state: { store.state(key) },
            observe: { onChange in store.observe(key, onChange) },
            takeOver: { _ = try store.perform(.takeOver, machine: machine, byPerson: true) },
            handBack: { _ = try store.perform(.handBack, machine: machine, byPerson: true) },
            send: nil,
            openInteractive: openInteractive
        )
    }
}
