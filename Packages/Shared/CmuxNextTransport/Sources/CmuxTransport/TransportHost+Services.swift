import Foundation

extension TransportHost {
    /// Post-admission control-lane listener: handles in-session grant renewal
    /// (3.6c). Ends when the connection dies, which is also where the session
    /// table learns about natural connection loss: without reaping here the
    /// table lies (8.2), `status` reports a dead phone as present, and
    /// anything gating on liveness (the rig's rotation gate) deadlocks.
    func runControlService(key: SessionKey, connection: any PeerConnection) async {
        defer {
            if let session = sessions[key], session.connection === connection {
                sessions.removeValue(forKey: key)
                // Take the echo/chat siblings down with the session; on a
                // half-open connection their lanes never EOF on their own.
                // (Cancelling this task itself is a harmless no-op: it is
                // already returning.)
                session.cancelServices()
                counters.closesByCode["connection-lost", default: 0] += 1
                if TransportDebugLog.enabled {
                    TransportDebugLog.host.notice(
                        """
                        host control service ended session=\(session.id, privacy: .public) \
                        device=\(TransportDebugLog.prefix(key.deviceID), privacy: .public) \
                        conn=\(TransportDebugLog.id(connection), privacy: .public) \
                        code=connection-lost \
                        liveSessions=\(self.sessions.count, privacy: .public)
                        """)
                }
            } else if TransportDebugLog.enabled {
                TransportDebugLog.host.notice(
                    """
                    host control service ended for superseded conn \
                    device=\(TransportDebugLog.prefix(key.deviceID), privacy: .public) \
                    conn=\(TransportDebugLog.id(connection), privacy: .public)
                    """)
            }
        }
        let control = await connection.lane(Self.controlLaneName)
        for await frame in control.frames {
            switch frameTypePolicy.classify(frame.type) {
            case .known:
                break
            case .ignorableUnknown:
                // Optional extensions are explicitly forward-compatible.
                continue
            case .fatalUnknown:
                if TransportDebugLog.enabled {
                    TransportDebugLog.host.error(
                        """
                        host ctl unknown mandatory frame; closing \
                        type=\(frame.type, privacy: .public) \
                        device=\(TransportDebugLog.prefix(key.deviceID), privacy: .public) \
                        conn=\(TransportDebugLog.id(connection), privacy: .public)
                        """)
                }
                await connection.closeAll(
                    reason: ConnectionTermination(code: DenialCode.protocolMismatch.rawValue))
                return
            }
            guard frame.type == FrameTypePolicy.grantUpdate else {
                if TransportDebugLog.enabled {
                    TransportDebugLog.host.notice(
                        """
                        host ctl frame ignored type=\(frame.type, privacy: .public) \
                        device=\(TransportDebugLog.prefix(key.deviceID), privacy: .public) \
                        conn=\(TransportDebugLog.id(connection), privacy: .public)
                        """)
                }
                continue
            }
            // Ignore frames from a superseded session's connection.
            guard let session = sessions[key], session.connection === connection else {
                if TransportDebugLog.enabled {
                    TransportDebugLog.host.notice(
                        """
                        host grant renewal from superseded conn ignored \
                        device=\(TransportDebugLog.prefix(key.deviceID), privacy: .public) \
                        conn=\(TransportDebugLog.id(connection), privacy: .public)
                        """)
                }
                return
            }
            guard let renewed = PairingGrant(payloadValue: frame.payload["grant"]) else {
                counters.grantRenewalRejections += 1
                if TransportDebugLog.enabled {
                    TransportDebugLog.host.error(
                        """
                        host grant renewal MALFORMED session=\(session.id, privacy: .public) \
                        device=\(TransportDebugLog.prefix(key.deviceID), privacy: .public) \
                        rejections=\(self.counters.grantRenewalRejections, privacy: .public)
                        """)
                }
                try? await control.send(Frame.grantAck(accepted: false, code: .malformedHello))
                continue
            }
            let expectedAccountID = await accountIDProvider?()
            guard sessions[key]?.connection === connection else {
                return
            }
            let decision: AdmissionDecision
            if accountIDProvider != nil && expectedAccountID == nil {
                decision = .deny(.accountMismatch)
            } else {
                decision = verifier.decide(
                    grant: renewed, presentedByKey: session.deviceKey,
                    presentedByDeviceID: key.deviceID, presentedByApp: key.appIdentity,
                    revokedGrantIDs: revokedGrantIDs, now: verificationNow(),
                    expectedAccountID: expectedAccountID)
            }
            switch decision {
            case .admit:
                sessions[key]?.grant = renewed
                sessions[key]?.warnedExpiring = false
                counters.grantRenewals += 1
                if TransportDebugLog.enabled {
                    TransportDebugLog.host.notice(
                        """
                        host grant renewal ACCEPTED session=\(session.id, privacy: .public) \
                        device=\(TransportDebugLog.prefix(key.deviceID), privacy: .public) \
                        grantID=\(TransportDebugLog.prefix(renewed.grantID), privacy: .public) \
                        newExp=\(renewed.expiresAt.map(String.init) ?? "none", privacy: .public) \
                        renewals=\(self.counters.grantRenewals, privacy: .public)
                        """)
                }
                try? await control.send(Frame.grantAck(accepted: true))
            case .deny(let code):
                // The session is NOT closed: the old grant still governs
                // until its grace window lapses (3.6d).
                counters.grantRenewalRejections += 1
                if TransportDebugLog.enabled {
                    TransportDebugLog.host.error(
                        """
                        host grant renewal REJECTED session=\(session.id, privacy: .public) \
                        device=\(TransportDebugLog.prefix(key.deviceID), privacy: .public) \
                        code=\(code.rawValue, privacy: .public) \
                        grantID=\(TransportDebugLog.prefix(renewed.grantID), privacy: .public) \
                        rejections=\(self.counters.grantRenewalRejections, privacy: .public) \
                        (session stays open under old grant)
                        """)
                }
                try? await control.send(Frame.grantAck(accepted: false, code: code))
            }
        }
    }

    /// Chat fan-out: every chat frame from one peer forwards to every OTHER
    /// registered peer. Demo-grade backpressure policy: a peer that stops
    /// reading its chat lane stalls forwarding from THIS source (clients
    /// always read theirs); production fan-out gets the sync layer's
    /// cursor/coalescing treatment, out of transport scope by contract 5.4.
    func runChatService(key: SessionKey, connection: any PeerConnection) async {
        let lane = await connection.lane(Self.chatLaneName)
        guard let session = sessions[key], session.connection === connection else { return }
        chatEndpoints[key] = ChatEndpoint(owner: ObjectIdentifier(connection), lane: lane)
        if TransportDebugLog.enabled {
            TransportDebugLog.host.notice(
                """
                host chat service registered session=\(session.id, privacy: .public) \
                device=\(TransportDebugLog.prefix(key.deviceID), privacy: .public) \
                endpoints=\(self.chatEndpoints.count, privacy: .public)
                """)
        }
        for await frame in lane.frames {
            switch frameTypePolicy.classify(frame.type) {
            case .known:
                break
            case .ignorableUnknown:
                continue
            case .fatalUnknown:
                await connection.closeAll(
                    reason: ConnectionTermination(code: DenialCode.protocolMismatch.rawValue))
                return
            }
            guard frame.type == FrameTypePolicy.chatMessage || frame.type == FrameTypePolicy.chatTyping
            else { continue }
            for (otherKey, endpoint) in chatEndpoints where otherKey != key {
                try? await endpoint.lane.send(frame)
            }
        }
        // Unregister only if this connection still owns the slot (a
        // superseding session may have re-registered the same key).
        if chatEndpoints[key]?.owner == ObjectIdentifier(connection) {
            chatEndpoints.removeValue(forKey: key)
        }
        if TransportDebugLog.enabled {
            TransportDebugLog.host.notice(
                """
                host chat service ended device=\(TransportDebugLog.prefix(key.deviceID), privacy: .public) \
                conn=\(TransportDebugLog.id(connection), privacy: .public) \
                endpoints=\(self.chatEndpoints.count, privacy: .public)
                """)
        }
    }

    func runEchoService(connection: any PeerConnection) async {
        let echo = await connection.lane(Self.echoLaneName)
        for await frame in echo.frames {
            switch frameTypePolicy.classify(frame.type) {
            case .known:
                break
            case .ignorableUnknown:
                continue
            case .fatalUnknown:
                await connection.closeAll(
                    reason: ConnectionTermination(code: DenialCode.protocolMismatch.rawValue))
                return
            }
            guard frame.type == FrameTypePolicy.dataChunk else { continue }
            do {
                try await echo.send(frame)
            } catch {
                if TransportDebugLog.enabled {
                    TransportDebugLog.host.error(
                        """
                        host echo service send FAILED \
                        conn=\(TransportDebugLog.id(connection), privacy: .public) \
                        error=\(String(describing: error), privacy: .public)
                        """)
                }
                return
            }
        }
        if TransportDebugLog.enabled {
            TransportDebugLog.host.notice(
                """
                host echo service ended conn=\(TransportDebugLog.id(connection), privacy: .public)
                """)
        }
    }
}
