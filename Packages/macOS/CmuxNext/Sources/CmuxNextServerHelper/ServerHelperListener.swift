import CmuxNextCompatCore
public import Foundation

/// The helper's listener: accepts a connection only from the app bundle that
/// carries the helper, signed by the helper's own team. The team comes from
/// the helper's own signature, so no team id is hard-coded and an unsigned or
/// ad hoc helper accepts nobody.
///
/// The `NSXPCListener` stays with its owner (the daemon's main code); XPC calls
/// the delegate, a ``ServerHelperClientGate`` of Sendable values, on its own queue.
public final nonisolated class ServerHelperListener {
    private let listener: NSXPCListener
    /// Strong here: `NSXPCListener.delegate` is weak.
    private let gate: ServerHelperClientGate

    public init(machServiceName: String, appBundleID: String, service: ServerHelperService = ServerHelperService()) {
        listener = NSXPCListener(machServiceName: machServiceName)
        gate = ServerHelperClientGate(
            requirement: ServerHelperConstants().clientRequirement(teamID: ServerHelperListener.ownTeamIdentifier(), appBundleID: appBundleID),
            service: service
        )
        listener.delegate = gate
    }

    /// False when the helper cannot serve anyone (no team in its signature).
    public var acceptsClients: Bool { gate.requirement != nil }

    public func resume() { listener.resume() }

    /// The team identifier of the running process, or nil when it is unsigned or ad hoc: the helper reads
    /// it once, at start, before it serves anyone (`RunningCodeSigningTeam`; the app reads its own team
    /// from CmuxNextCompat's `SigningTeamInstall.process`, which a lane loads at launch).
    static func ownTeamIdentifier() -> String? {
        RunningCodeSigningTeam().read()
    }
}

/// The listener's delegate: puts the client requirement on each new connection
/// and exports the service. It holds only Sendable values, so XPC's queue may
/// call it at any time.
final nonisolated class ServerHelperClientGate: NSObject, NSXPCListenerDelegate, Sendable {
    /// Nil when the helper has no team: it accepts nobody.
    let requirement: String?
    private let service: ServerHelperService

    init(requirement: String?, service: ServerHelperService) {
        self.requirement = requirement
        self.service = service
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let requirement else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: (any ServerHelperProtocol).self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}
