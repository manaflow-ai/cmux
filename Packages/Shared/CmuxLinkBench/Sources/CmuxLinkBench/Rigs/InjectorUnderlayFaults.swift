import CmuxLink
import CmuxLinkWGTesting
@_spi(Testing) import CmuxLinkWebRTC

/// `UnderlayFaults` over `WebRTCFaultInjector`.
struct InjectorUnderlayFaults: UnderlayFaults {
    let injector: WebRTCFaultInjector

    func reset() async { await injector.resetAll() }
    func changePath(to kind: PathKind) async { await injector.changePath(to: kind) }
    func roam(to kind: PathKind) async { await injector.roam(to: kind) }
    func throttle(bytesPerSecond: Int?) async -> Bool {
        injector.throttle(bytesPerSecond: bytesPerSecond)
        return true
    }
}
