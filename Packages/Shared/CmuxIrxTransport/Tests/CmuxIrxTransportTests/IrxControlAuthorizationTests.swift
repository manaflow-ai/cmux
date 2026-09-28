import Foundation
import IrohLib
import Testing

@testable import CmuxIrxTransport

/// Admission proves the peer once; the write gate must reject a revoked lease
/// even when the control lane was already admitted and previously writable.
@Suite("control transport authorization", .serialized, .timeLimit(.minutes(1)))
struct IrxControlAuthorizationTests {
    @Test("revoking an established control lane prevents the next write and closes its session")
    func revokedLeaseClosesBeforeWrite() async throws {
        try await IrxControlAuthorizationFixture.withConnection { fixture in
            let gate = PermitGate()
            let release = IrxControlReleaseProbe()
            let transport = IrxControlByteTransport(
                closeCode: .revoked,
                establish: { (fixture.clientConnection, fixture.clientControl) },
                onClose: { _, closeCode, retiresConnection in
                    await release.record(closeCode: closeCode, retiresConnection: retiresConnection)
                },
                permitsIO: { await gate.isAllowed() }
            )
            try await transport.connect()
            let authorizedPayload = Data("authorized before revocation".utf8)
            try await transport.send(authorizedPayload)
            #expect(try await fixture.readServerBytes(count: authorizedPayload.count) == authorizedPayload)
            #expect(await !transport.isTransportClosed())

            await gate.revoke()
            var rejected = false
            do {
                try await transport.send(Data("must not cross the revoked link".utf8))
                Issue.record("send succeeded after lease revocation")
            } catch let error as IrxConnectionError {
                if case .closed = error { rejected = true }
                else { throw error }
            }
            #expect(rejected)
            #expect(await transport.isTransportClosed())
            #expect(await fixture.clientConnection.isClosed)
            #expect(await gate.checks == 2, "an existing pair still checks every write")
            #expect(await release.count == 1)
            #expect(await release.closeCodes == [.revoked])
            #expect(await release.retiresConnections == [true])

            // Even a regression that omits the gate must finish: the failed
            // assertions above detect it before this cleanup closes its session.
            await transport.close()
            var unexpectedBytes = Data()
            do {
                while let chunk = try await fixture.serverControl.reader.readRaw() {
                    unexpectedBytes.append(chunk)
                }
            } catch {
                // QUIC can terminate a revoked lane with EOF or a close error.
            }
            #expect(unexpectedBytes.isEmpty, "revoked application bytes reached the peer")
            _ = await fixture.serverConnection.carrier.closed()
            #expect(await fixture.serverConnection.isClosed)
        }
    }

    @Test("omitting the optional gate keeps an admitted control lane writable")
    func defaultPermitAllowsWrite() async throws {
        try await IrxControlAuthorizationFixture.withConnection { fixture in
            let transport = IrxControlByteTransport(
                closeCode: .userRequested,
                establish: { (fixture.clientConnection, fixture.clientControl) }
            )
            try await transport.connect()
            for payload in [Data("first authorized payload".utf8), Data("second authorized payload".utf8)] {
                try await transport.send(payload)
                #expect(try await fixture.readServerBytes(count: payload.count) == payload)
            }
            #expect(await !transport.isTransportClosed())
            #expect(await !fixture.clientConnection.isClosed)
            await transport.close()
        }
    }

    private actor PermitGate {
        private var allowed = true
        private(set) var checks = 0

        func isAllowed() -> Bool {
            checks += 1
            return allowed
        }

        func revoke() { allowed = false }
    }
}
