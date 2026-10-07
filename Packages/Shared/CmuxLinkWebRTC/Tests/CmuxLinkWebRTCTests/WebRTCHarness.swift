import CmuxLink
import CmuxLinkTesting
@_spi(Testing) import CmuxLinkWebRTC

/// `LinkConformanceSuite` over two in-process libwebrtc peers: real ICE on
/// loopback host candidates, DTLS, SCTP data channels, signaling through an
/// in-memory relay. Drop closes real peer connections; path change, roam and
/// throttle go through `WebRTCFaultInjector`.
final class WebRTCHarness: ConformanceHarness {
    let name = "webrtc-loopback"
    private let box = WebRTCPairBox()

    func makeEndpoints() async throws -> ConformanceEndpoints {
        let pair = await WebRTCPair()
        await box.set(pair)
        return ConformanceEndpoints(carriers: [pair.carrier], acceptor: pair.acceptor, peer: pair.peer)
    }

    func dropTransports() async -> Bool {
        guard let pair = await box.pair else { return false }
        await pair.injector.dropAll()
        return true
    }

    func changePath(to kind: PathKind) async -> Bool {
        guard let pair = await box.pair else { return false }
        await pair.injector.changePath(to: kind)
        return true
    }

    func roam(to kind: PathKind) async -> Bool {
        guard let pair = await box.pair else { return false }
        await pair.injector.roam(to: kind)
        return true
    }

    func throttle(bytesPerSecond: Int?) async -> Bool {
        guard let pair = await box.pair else { return false }
        pair.injector.throttle(bytesPerSecond: bytesPerSecond)
        return true
    }

    func tearDown() async {
        await box.pair?.stop()
        await box.set(nil)
    }
}

actor WebRTCPairBox {
    private(set) var pair: WebRTCPair?

    func set(_ pair: WebRTCPair?) {
        self.pair = pair
    }
}
