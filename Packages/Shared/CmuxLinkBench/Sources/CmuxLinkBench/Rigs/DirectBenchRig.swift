import CmuxLink
@_spi(Testing) import CmuxLinkDirect
import CmuxLinkTesting

/// V3: NWListener on 127.0.0.1 and an NWConnection dialer with the real
/// Noise IK handshake and record layer. Drop and roam close the sockets
/// through `DirectFaultInjector`; delay and loss need the dnctl recipe.
final class DirectBenchRig: ConformanceHarness {
    let name = "v3-direct-localhost"
    private let state = RigState<DirectFaultInjector, DirectAcceptor>()

    func makeEndpoints() async throws -> ConformanceEndpoints {
        let hostID = "h_bench01"
        let host = DirectIdentity()
        let device = DirectIdentity()
        let injector = DirectFaultInjector()
        let acceptor = DirectAcceptor(
            identity: host,
            hostID: hostID,
            configuration: DirectListenConfiguration(port: 0, localAddress: "127.0.0.1"),
            authorizer: DirectPinnedAuthorizer(allowed: [device.publicKey]),
            faultInjector: injector
        )
        let port = try await acceptor.start()
        guard let address = DirectAddress("127.0.0.1") else { throw BenchError.setup("no loopback address") }
        let endpoint = DirectEndpoint(address: address, port: port, hostKey: host.publicKey)
        let carrier = DirectCarrier(identity: device, resolver: DirectHintsResolver(), routes: nil, faultInjector: injector)
        await state.set(injector, acceptor)
        return ConformanceEndpoints(
            carriers: [carrier],
            acceptor: acceptor,
            peer: LinkPeer(hostID: hostID, hints: DirectHintsResolver().hints(for: endpoint))
        )
    }

    func dropTransports() async -> Bool {
        guard let injector = await state.faults else { return false }
        injector.dropAll()
        return true
    }

    func changePath(to kind: PathKind) async -> Bool {
        guard let injector = await state.faults else { return false }
        injector.changePath(to: kind)
        return true
    }

    func roam(to kind: PathKind) async -> Bool {
        guard let injector = await state.faults else { return false }
        injector.roam(to: kind)
        return true
    }

    func tearDown() async {
        await state.owner?.stop()
        await state.set(nil, nil)
    }
}
