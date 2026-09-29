import Testing
@testable import CmuxIrxTransport

@Suite struct IrxSessionProbeOwnershipTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func oldProbeReusesTheInstalledReplacement(readOnly: Bool) async throws {
        let original = try await IrxReconnectTestSession.make()
        let replacement = try await IrxReconnectTestSession.make()
        let unwanted = try await IrxReconnectTestSession.make()
        let dials = IrxControlledDialSequence(
            sessions: [original.session, replacement.session, unwanted.session])
        let probe = IrxHeldSessionProbe(original.session.connection)
        let engine = IrxPeerEngine(journal: IrxLiveTestSupport.journal(),
            connectionIsClosed: { await probe.isClosed($0) },
            dialOnce: { await dials.dial() })
        _ = try await engine.ensureSession(trigger: "initial")
        let delayed = Task {
            if readOnly { return await engine.currentSession() }
            return try await engine.ensureSession(trigger: "reuse")
        }
        await probe.gate.waitUntilStarted()
        let installed = try await engine.ensureSession(explicit: true, trigger: "replacement")
        await probe.gate.release()
        let observed = try await delayed.value
        #expect(observed?.connection === installed.connection,
                "a delayed probe must re-read the replacement's authority")
        #expect(await dials.count == 2, "a replacement already satisfies the waiting caller")
        #expect(await engine.currentSession()?.connection === installed.connection)
        if observed?.connection === installed.connection {
            try await replacement.verifyRoundTrip()
        }
        await engine.stop()
        await original.close(); await replacement.close(); await unwanted.close()
    }
}
