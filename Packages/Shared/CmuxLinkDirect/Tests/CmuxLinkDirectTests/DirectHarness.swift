import CmuxLink
import CmuxLinkTesting
@_spi(Testing) import CmuxLinkDirect

/// `LinkConformanceSuite` over real sockets: NWListener on 127.0.0.1, an
/// NWConnection dialer, the real Noise handshake and record layer.
final class DirectHarness: ConformanceHarness {
    let name = "direct-localhost"
    private let box = PairBox()

    func makeEndpoints() async throws -> ConformanceEndpoints {
        let pair = try await LocalhostPair()
        await box.set(pair)
        return ConformanceEndpoints(carriers: [pair.carrier()], acceptor: pair.acceptor, peer: pair.peer())
    }

    func dropTransports() async -> Bool {
        guard let pair = await box.pair else { return false }
        pair.injector.dropAll()
        return true
    }

    func changePath(to kind: PathKind) async -> Bool {
        guard let pair = await box.pair else { return false }
        pair.injector.changePath(to: kind)
        return true
    }

    func roam(to kind: PathKind) async -> Bool {
        guard let pair = await box.pair else { return false }
        pair.injector.roam(to: kind)
        return true
    }

    func throttle(bytesPerSecond: Int?) async -> Bool {
        guard let pair = await box.pair else { return false }
        await pair.injector.throttle(bytesPerSecond: bytesPerSecond)
        return true
    }

    func tearDown() async {
        await box.pair?.acceptor.stop()
        await box.set(nil)
    }
}

actor PairBox {
    private(set) var pair: LocalhostPair?

    func set(_ pair: LocalhostPair?) {
        self.pair = pair
    }
}
