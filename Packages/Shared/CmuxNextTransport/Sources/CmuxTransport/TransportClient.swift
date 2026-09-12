import Foundation

/// Client-side connect helper: sends hello, awaits the single-phase verdict.
public struct TransportClient: Sendable {
    /// Creates the stateless TransportClient operation value.
    public init() {}

    /// Single-phase admission verdict, distinct from a transport failure thrown by connect.
    public enum ConnectOutcome: Sendable, Equatable {
        /// Host accepted the peer and assigned a nonempty session identifier.
        case admitted(sessionID: String)
        /// Host refused admission with a recognized, typed denial code.
        case denied(DenialCode)
    }

    /// Performs the admission exchange with a cancellation escape hatch. A
    /// cancelled FFI lane read is explicitly woken by closing the connection;
    /// this keeps caller deadlines effective even when the underlying future
    /// does not observe Swift task cancellation on its own.
    /// - Parameters:
    ///   - connection: Established substrate connection owned by this attempt.
    ///   - identity: Local identity whose public fields enter the hello.
    ///   - grant: Host-signed admission grant for this identity.
    /// - Returns: Successful admission or an explicit host denial.
    /// - Throws: Cancellation, send failure, or an absent or malformed admission reply.
    #if compiler(>=6.2)
    @concurrent
    #endif
    public func connect(
        connection: any PeerConnection, identity: PeerIdentity, grant: PairingGrant
    ) async throws -> ConnectOutcome {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await connectUncancelled(
                connection: connection, identity: identity, grant: grant)
        }, onCancel: {
            Task {
                await connection.closeAll(
                    reason: ConnectionTermination(code: "admission-cancelled"))
            }
        })
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    private func connectUncancelled(
        connection: any PeerConnection, identity: PeerIdentity, grant: PairingGrant
    ) async throws -> ConnectOutcome {
        let connectStart = ContinuousClock.now
        let control = await connection.lane("ctl")
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                client hello send conn=\(TransportDebugLog.id(connection), privacy: .public) \
                device=\(TransportDebugLog.prefix(identity.deviceID), privacy: .public) \
                app=\(identity.appIdentity, privacy: .public) \
                grantID=\(TransportDebugLog.prefix(grant.grantID), privacy: .public)
                """)
        }
        try await control.send(Frame.hello(identity: identity, grant: grant))
        guard let reply = await control.receive() else {
            // No admit frame: a denial. The reason arrives in the connection
            // termination itself, delivered by the substrate without any
            // timing dependence (contract 3.3 v7).
            if let termination = await connection.termination(),
                let code = DenialCode(rawValue: termination.code)
            {
                if TransportDebugLog.enabled {
                    TransportDebugLog.core.error(
                        """
                        client connect DENIED conn=\(TransportDebugLog.id(connection), privacy: .public) \
                        device=\(TransportDebugLog.prefix(identity.deviceID), privacy: .public) \
                        code=\(code.rawValue, privacy: .public) \
                        elapsedMs=\(TransportDebugLog.ms(since: connectStart), privacy: .public)
                        """)
                }
                return .denied(code)
            }
            if TransportDebugLog.enabled {
                TransportDebugLog.core.error(
                    """
                    client connect FAILED conn=\(TransportDebugLog.id(connection), privacy: .public) \
                    device=\(TransportDebugLog.prefix(identity.deviceID), privacy: .public) \
                    cause=connection-closed-before-reply (no parsable termination) \
                    elapsedMs=\(TransportDebugLog.ms(since: connectStart), privacy: .public)
                    """)
            }
            throw TransportError.connectionClosedBeforeReply
        }
        guard reply.type == FrameTypePolicy.admit else {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.error(
                    """
                    client connect FAILED conn=\(TransportDebugLog.id(connection), privacy: .public) \
                    device=\(TransportDebugLog.prefix(identity.deviceID), privacy: .public) \
                    cause=unexpected-frame type=\(reply.type, privacy: .public) \
                    elapsedMs=\(TransportDebugLog.ms(since: connectStart), privacy: .public)
                    """)
            }
            throw TransportError.unexpectedFrame(reply.type)
        }
        guard let sessionID = reply.payload["session"]?.stringValue,
            !sessionID.isEmpty
        else {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.error(
                    "client connect FAILED conn=\(TransportDebugLog.id(connection), privacy: .public) cause=empty-admit-session")
            }
            throw TransportError.unexpectedFrame("ctl.admit.empty-session")
        }
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                client connect ADMITTED conn=\(TransportDebugLog.id(connection), privacy: .public) \
                device=\(TransportDebugLog.prefix(identity.deviceID), privacy: .public) \
                session=\(TransportDebugLog.prefix(sessionID), privacy: .public) \
                elapsedMs=\(TransportDebugLog.ms(since: connectStart), privacy: .public)
                """)
        }
        return .admitted(sessionID: sessionID)
    }
}
