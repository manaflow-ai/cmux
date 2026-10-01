import Foundation
import IrohLib
import Testing
@testable import CmuxIrxTransport

/// Admitted loopback peers with an application control lane in both directions.
struct IrxReconnectTestSession: Sendable {
    let client: Endpoint
    let server: Endpoint
    let session: IrxClientSession
    let hostConnection: IrxConnection
    let hostControl: IrxLaneStream

    static func make() async throws -> Self {
        let journal = IrxLiveTestSupport.journal()
        let server = try await IrxLiveTestSupport.bindLoopback(seed: IrxLiveTestSupport.identitySeed(), remoteBiCredit: 1)
        let client = try await IrxLiveTestSupport.bindLoopback(seed: IrxLiveTestSupport.identitySeed(), remoteBiCredit: 0)
        let host = Task { () throws -> (IrxConnection, IrxLaneStream) in
            let incoming = try #require(await server.acceptNext())
            let native = try await incoming.accept().connect()
            let connection = IrxConnection(connection: native, role: .acceptor, journal: journal)
            let (_, lane, _) = try #require(await IrxAdmission().performServer(
                connection: connection,
                judgment: IrxLiveTestSupport.fixedJudgment(accepting: "good-grant"), journal: journal))
            return (connection, lane)
        }
        let native = try await client.connect(addr: IrxLiveTestSupport.loopbackAddr(of: server), alpn: IrxProtocol().alpnData)
        let connection = IrxConnection(connection: native, role: .dialer, journal: journal)
        let (admit, control) = try await IrxAdmission().performClient(connection: connection, grantJWS: "good-grant", journal: journal)
        let (hostConnection, hostControl) = try await host.value
        return Self(client: client, server: server,
                    session: IrxClientSession(connection: connection, admit: admit, control: control, establishedAt: Date()),
                    hostConnection: hostConnection, hostControl: hostControl)
    }

    func verifyRoundTrip() async throws {
        try await session.control.writer.writeControlFrame("recovered")
        #expect(try await hostControl.reader.readControlFrame(String.self) == "recovered")
        try await hostControl.writer.writeControlFrame("ack")
        #expect(try await session.control.reader.readControlFrame(String.self) == "ack")
    }

    func close() async {
        await session.connection.close(code: .userRequested, origin: .local)
        await hostConnection.close(code: .hostShutdown, origin: .local)
        try? await client.close()
        try? await server.close()
    }
}
