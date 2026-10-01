import Foundation
import IrohLib
import Testing

@testable import CmuxIrxTransport

/// An RPC client generation that is replaced while its dial is still in
/// flight never reads or writes the control lane. When that dial lands it
/// must hand its claim back and leave the admitted session to the owner that
/// replaced it. Retiring the session instead forced a second dial on every
/// connect, and after a Mac stall it cost a whole extra reconnect cycle.
@Suite("superseded control owner", .serialized, .timeLimit(.minutes(1)))
struct IrxControlSupersededOwnerTests {
    @Test("an owner closed during its dial releases its claim and keeps the session")
    func ownerClosedDuringDialKeepsTheSession() async throws {
        try await IrxControlAuthorizationFixture.withConnection { fixture in
            let dial = PendingDial()
            let release = IrxControlReleaseProbe()
            let superseded = IrxControlByteTransport(
                closeCode: .explicitRedial,
                establish: {
                    await dial.waitUntilReleased()
                    return (fixture.clientConnection, fixture.clientControl)
                },
                onClose: { _, closeCode, retiresConnection in
                    await release.record(closeCode: closeCode, retiresConnection: retiresConnection)
                }
            )
            let connect = Task { try await superseded.connect() }
            #expect(try await dial.waitUntilStarted())

            // A newer client generation replaces this one before the dial lands.
            await superseded.close()
            await dial.release()
            await #expect(throws: IrxConnectionError.self) { try await connect.value }

            // The closed owner returns at once; its late dial reports the release.
            #expect(try await release.waitForRelease())
            #expect(await release.count == 1)
            #expect(await release.retiresConnections == [false])
            #expect(await !fixture.clientConnection.isConnectionClosed())

            // The replacement owner claims the same session and its lane works.
            let replacement = IrxControlByteTransport(
                closeCode: .explicitRedial,
                establish: { (fixture.clientConnection, fixture.clientControl) }
            )
            try await replacement.connect()
            let payload = Data("replacement owner".utf8)
            try await replacement.send(payload)
            #expect(try await fixture.readServerBytes(count: payload.count) == payload)
            await replacement.close()
        }
    }
}

/// An establish step held until the test releases it, like a dial in flight.
private actor PendingDial {
    private var started = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    func waitUntilReleased() async {
        started = true
        guard !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }

    func waitUntilStarted() async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !started, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        return started
    }
}
