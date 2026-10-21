/// Immutable admission facts and resources owned by one control transport.
struct DaemonReadyConnection: Sendable {
    let transport: LineTransport
    let serial: UInt64
    let identity: DaemonIdentity
    let userOriginAllowed: Bool
    let inventoryWatch: AgentInventoryWatch?

    /// The latest routed position on this captured control transport.
    var eventSequence: UInt64 { DaemonEventEnvelope.sequence(serial: serial, index: transport.routedEventCount) }

    init(transport: LineTransport, serial: UInt64, identity: DaemonIdentity, userOriginAllowed: Bool) {
        self.transport = transport
        self.serial = serial
        self.identity = identity
        self.userOriginAllowed = userOriginAllowed
        inventoryWatch = identity.machineResourceID.flatMap { machine in
            guard MachineCatalogRecord.validID(machine) else { return nil }
            return AgentInventoryWatch(transport: transport, machine: machine,
                                       supportsReceipts: identity.supports("agent-inventory-watch-admission-v1"))
        }
    }
}
