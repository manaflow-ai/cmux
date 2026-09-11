import Foundation

extension TransportHost {
    private enum HelloReadOutcome: Sendable {
        case frame(Frame)
        case eof
        case timeout
    }
    /// Supplies the account currently authenticated on the host. When set,
    /// Serve one incoming connection: read ctl.hello, decide, admit or deny.
    /// Single-phase admission on the first control frame (contract 3.2).
    public func serve(connection: any PeerConnection, now: Int64) async {
        currentTime = now
        let serveStart = ContinuousClock.now
        if TransportDebugLog.enabled {
            TransportDebugLog.host.notice(
                """
                host serve begin conn=\(TransportDebugLog.id(connection), privacy: .public) \
                now=\(now, privacy: .public) \
                liveSessions=\(self.sessions.count, privacy: .public)
                """)
        }
        let control = await connection.lane(Self.controlLaneName)
        guard let hello = await receiveHello(
            from: control, connection: connection), hello.type == FrameTypePolicy.hello else {
            if TransportDebugLog.enabled {
                TransportDebugLog.host.error(
                    """
                    host hello parse failed conn=\(TransportDebugLog.id(connection), privacy: .public): \
                    no frame or wrong type
                    """)
            }
            if await !connection.isClosed {
                await deny(.malformedHello, connection: connection)
            }
            return
        }
        if let override = admissionOverride {
            if TransportDebugLog.enabled {
                TransportDebugLog.host.notice(
                    """
                    host admission override firing conn=\(TransportDebugLog.id(connection), privacy: .public) \
                    code=\(override.rawValue, privacy: .public)
                    """)
            }
            await deny(
                override, connection: connection,
                deviceID: hello.payload["deviceId"]?.stringValue)
            return
        }
        guard hello.payload["protocol"]?.stringValue == Frame.protocolIdentifier else {
            if TransportDebugLog.enabled {
                TransportDebugLog.host.error(
                    """
                    host protocol mismatch conn=\(TransportDebugLog.id(connection), privacy: .public) \
                    presented=\(hello.payload["protocol"]?.stringValue ?? "nil", privacy: .public) \
                    expected=\(Frame.protocolIdentifier, privacy: .public)
                    """)
            }
            await deny(
                .protocolMismatch, connection: connection,
                deviceID: hello.payload["deviceId"]?.stringValue)
            return
        }
        guard
            let helloKey = hello.payload["key"]?.dataValue,
            let deviceID = hello.payload["deviceId"]?.stringValue,
            let appIdentity = hello.payload["app"]?.stringValue,
            let grant = PairingGrant(payloadValue: hello.payload["grant"])
        else {
            if TransportDebugLog.enabled {
                TransportDebugLog.host.error(
                    """
                    host hello missing fields conn=\(TransportDebugLog.id(connection), privacy: .public) \
                    key=\(hello.payload["key"]?.dataValue != nil, privacy: .public) \
                    deviceId=\(hello.payload["deviceId"]?.stringValue != nil, privacy: .public) \
                    app=\(hello.payload["app"]?.stringValue != nil, privacy: .public) \
                    grant=\(PairingGrant(payloadValue: hello.payload["grant"]) != nil, privacy: .public)
                    """)
            }
            await deny(
                .malformedHello, connection: connection,
                deviceID: hello.payload["deviceId"]?.stringValue)
            return
        }

        // Contract 3.5: when the substrate authenticated the remote key, that
        // key is the truth. A hello that self-reports a different key is a
        // protocol violation, and the grant is judged against the
        // authenticated key, never the claimed one.
        let substrateKey = await connection.authenticatedRemoteKey
        if let substrateKey, substrateKey != helloKey {
            if TransportDebugLog.enabled {
                TransportDebugLog.host.error(
                    """
                    host key mismatch conn=\(TransportDebugLog.id(connection), privacy: .public) \
                    device=\(TransportDebugLog.prefix(deviceID), privacy: .public) \
                    substrateKey=\(TransportDebugLog.hex8(substrateKey), privacy: .public) \
                    helloKey=\(TransportDebugLog.hex8(helloKey), privacy: .public)
                    """)
            }
            await deny(.keyMismatch, connection: connection, deviceID: deviceID)
            return
        }
        let presentedKey = substrateKey ?? helloKey

        let expectedAccountID = await accountIDProvider?()
        let decision: AdmissionDecision
        if accountIDProvider != nil && expectedAccountID == nil {
            // A configured account provider that cannot produce an authenticated
            // identity is a signed-out host, never an unrestricted host.
            decision = .deny(.accountMismatch)
        } else {
            decision = verifier.decide(
                grant: grant, presentedByKey: presentedKey, presentedByDeviceID: deviceID,
                presentedByApp: appIdentity, revokedGrantIDs: revokedGrantIDs, now: now,
                expectedAccountID: expectedAccountID)
        }
        switch decision {
        case .deny(let code):
            if TransportDebugLog.enabled {
                TransportDebugLog.host.error(
                    """
                    host grant verification denied conn=\(TransportDebugLog.id(connection), privacy: .public) \
                    code=\(code.rawValue, privacy: .public) \
                    device=\(TransportDebugLog.prefix(deviceID), privacy: .public) \
                    app=\(appIdentity, privacy: .public) \
                    grantID=\(TransportDebugLog.prefix(grant.grantID), privacy: .public) \
                    grantExp=\(grant.expiresAt.map(String.init) ?? "none", privacy: .public)
                    """)
            }
            await deny(code, connection: connection, deviceID: deviceID)

        case .admit:
            // Supersession (contract 4.5): a new connection from the same
            // (device, app) identity IMMEDIATELY replaces the old session.
            // A dead process's session must never block re-admission; the
            // field logs showed an ~85s lockout doing exactly that.
            let key = SessionKey(deviceID: deviceID, appIdentity: appIdentity)
            admissionReservationCounter &+= 1
            let reservation = admissionReservationCounter
            admissionReservations[key] = reservation
            var supersededSessionID: String?
            if let old = sessions.removeValue(forKey: key) {
                supersededSessionID = old.id
                old.cancelServices()
                await old.connection.closeAll(
                    reason: ConnectionTermination(code: CloseReason.superseded.code))
                counters.closesByCode[CloseReason.superseded.code, default: 0] += 1
            }
            // The close above suspends this actor. A newer admission for the
            // same identity may have claimed the reservation while we waited;
            // never let this stale connection become an untracked session.
            guard admissionReservations[key] == reservation else {
                await connection.closeAll(
                    reason: ConnectionTermination(code: CloseReason.superseded.code))
                return
            }
            sessionCounter += 1
            let session = ActiveSession(
                id: "s\(sessionCounter)", connection: connection, deviceKey: presentedKey,
                grant: grant)
            sessions[key] = session
            counters.admissions += 1
            if TransportDebugLog.enabled {
                if let supersededSessionID {
                    TransportDebugLog.host.notice(
                        """
                        host supersession device=\(TransportDebugLog.prefix(deviceID), privacy: .public) \
                        app=\(appIdentity, privacy: .public) \
                        oldSession=\(supersededSessionID, privacy: .public) -> \
                        newSession=\(session.id, privacy: .public)
                        """)
                }
                TransportDebugLog.host.notice(
                    """
                    host ADMITTED session=\(session.id, privacy: .public) \
                    conn=\(TransportDebugLog.id(connection), privacy: .public) \
                    device=\(TransportDebugLog.prefix(deviceID), privacy: .public) \
                    app=\(appIdentity, privacy: .public) \
                    key=\(TransportDebugLog.hex8(presentedKey), privacy: .public) \
                    grantID=\(TransportDebugLog.prefix(grant.grantID), privacy: .public) \
                    grantExp=\(grant.expiresAt.map(String.init) ?? "none", privacy: .public) \
                    admissions=\(self.counters.admissions, privacy: .public) \
                    elapsedMs=\(TransportDebugLog.ms(since: serveStart), privacy: .public)
                    """)
            }
            try? await control.send(Frame.admit(sessionID: session.id))
            guard admissionReservations[key] == reservation,
                sessions[key]?.connection === connection
            else {
                await connection.closeAll(
                    reason: ConnectionTermination(code: CloseReason.superseded.code))
                return
            }
            if let credential = pendingRelayCredentials[key],
                Self.credentialExpired(token: credential.token, now: now)
            {
                // Provably stale: replaying it would hand the client a dead
                // relay route. Drop it; the next rotation push refills.
                pendingRelayCredentials.removeValue(forKey: key)
                if TransportDebugLog.enabled {
                    TransportDebugLog.host.notice(
                        """
                        host dropped expired pending relay credential \
                        session=\(session.id, privacy: .public) \
                        device=\(TransportDebugLog.prefix(deviceID), privacy: .public) \
                        url=\(credential.url, privacy: .public) \
                        tokenExp=\(IrohSubstrate().tokenExpiry(credential.token).map(String.init) ?? "unparsed", privacy: .public) \
                        now=\(now, privacy: .public)
                        """)
                }
            }
            if let credential = pendingRelayCredentials[key] {
                if TransportDebugLog.enabled {
                    TransportDebugLog.host.notice(
                        """
                        host replaying pending relay credential on admission \
                        session=\(session.id, privacy: .public) \
                        device=\(TransportDebugLog.prefix(deviceID), privacy: .public) \
                        url=\(credential.url, privacy: .public)
                        """)
                }
                try? await control.send(
                    Frame.relayCredential(url: credential.url, token: credential.token))
            }
            let serviceTasks = [
                Task { await self.runControlService(key: key, connection: connection) },
                Task { await self.runEchoService(connection: connection) },
                Task { await self.runChatService(key: key, connection: connection) },
            ]
            if let current = sessions[key], current.connection === connection {
                sessions[key]?.serviceTasks = serviceTasks
            } else {
                // Superseded during the admit send: these loops belong to a
                // session that is already gone. Kill them, never leak them.
                for task in serviceTasks { task.cancel() }
            }
            if admissionReservations[key] == reservation {
                admissionReservations.removeValue(forKey: key)
            }
        }
    }

    /// Reads the first control frame with a bounded, cancellation-aware
    /// deadline. Closing the connection on timeout wakes substrates whose FFI
    /// receive future does not observe task cancellation on its own.
    private func receiveHello(
        from control: any TransportLane,
        connection: any PeerConnection
    ) async -> Frame? {
        let outcome = await withTaskGroup(of: HelloReadOutcome.self) { group in
            group.addTask {
                guard let frame = await control.receive() else { return .eof }
                return .frame(frame)
            }
            let sleep = handshakeSleep
            group.addTask {
                do {
                    try await sleep(.seconds(10))
                } catch {
                    return .eof
                }
                return .timeout
            }
            let result = await group.next() ?? .eof
            group.cancelAll()
            if case .timeout = result {
                await connection.closeAll(
                    reason: ConnectionTermination(code: CloseReason.handshakeTimeout.code))
            }
            await group.waitForAll()
            return result
        }
        if case .frame(let frame) = outcome { return frame }
        return nil
    }

    /// One channel, no timing dependence (contract 3.3 v7): the code rides in
    /// the connection termination itself, which the substrate delivers as
    /// part of closing. There is no deny frame to race against the close.
    func deny(
        _ code: DenialCode, connection: any PeerConnection, deviceID: String? = nil
    ) async {
        counters.denialsByCode[code.rawValue, default: 0] += 1
        if TransportDebugLog.enabled {
            TransportDebugLog.host.error(
                """
                host DENIED conn=\(TransportDebugLog.id(connection), privacy: .public) \
                code=\(code.rawValue, privacy: .public) \
                device=\(TransportDebugLog.prefix(deviceID), privacy: .public) \
                denialsForCode=\(self.counters.denialsByCode[code.rawValue] ?? 0, privacy: .public)
                """)
        }
        await connection.closeAll(reason: ConnectionTermination(code: code.rawValue))
    }

}
