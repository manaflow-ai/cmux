import Foundation
import IrohLib
import Testing

@testable import CmuxIrxTransport

/// Two isolated live QUIC endpoints, released on test failure as well as success.
struct IrxControlAuthorizationFixture: Sendable {
    let server: Endpoint
    let client: Endpoint
    let serverConnection: IrxConnection
    let clientConnection: IrxConnection
    let serverControl: IrxLaneStream
    let clientControl: IrxLaneStream

    static func withConnection(
        _ body: (IrxControlAuthorizationFixture) async throws -> Void
    ) async throws {
        let fixture = try await make()
        do {
            try await body(fixture)
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    private static func make() async throws -> IrxControlAuthorizationFixture {
        let journal = IrxLiveTestSupport.journal()
        let server = try await IrxLiveTestSupport.bindLoopback(
            seed: IrxLiveTestSupport.identitySeed(), remoteBiCredit: 1)
        let client: Endpoint
        do {
            client = try await IrxLiveTestSupport.bindLoopback(
                seed: IrxLiveTestSupport.identitySeed(), remoteBiCredit: 0)
        } catch {
            try? await server.close()
            throw error
        }
        let serverTask = Task { () throws -> (IrxConnection, IrxLaneStream)? in
            guard let incoming = await server.acceptNext() else { return nil }
            let accepting = try await incoming.accept()
            let connection = try await accepting.connect()
            let irx = IrxConnection(connection: connection, role: .acceptor, journal: journal)
            guard let (_, control, _) = await IrxAdmission().performServer(
                connection: irx,
                judgment: IrxLiveTestSupport.fixedJudgment(accepting: "control-test-grant"),
                journal: journal
            ) else { return nil }
            return (irx, control)
        }
        do {
            let connection = try await client.connect(
                addr: IrxLiveTestSupport.loopbackAddr(of: server), alpn: IrxProtocol().alpnData)
            let clientConnection = IrxConnection(connection: connection, role: .dialer, journal: journal)
            let (_, clientControl) = try await IrxAdmission().performClient(
                connection: clientConnection, grantJWS: "control-test-grant", journal: journal)
            let serverPair = try #require(try await serverTask.value)
            return IrxControlAuthorizationFixture(
                server: server, client: client,
                serverConnection: serverPair.0, clientConnection: clientConnection,
                serverControl: serverPair.1, clientControl: clientControl
            )
        } catch {
            serverTask.cancel()
            try? await server.close()
            try? await client.close()
            throw error
        }
    }

    func readServerBytes(count: Int) async throws -> Data {
        var received = Data()
        while received.count < count, let chunk = try await serverControl.reader.readRaw() {
            received.append(chunk)
        }
        return received
    }

    func close() async {
        await serverConnection.close(code: .userRequested, origin: .local)
        await clientConnection.close(code: .userRequested, origin: .local)
        try? await server.close()
        try? await client.close()
    }
}
