import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileShellModel

@MainActor
final class LiveDirectoryDiscovery: MobileIrohMacDiscovering {
    private var candidates: [MobileDiscoveredIrohMac]
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init(candidates: [MobileDiscoveredIrohMac]) {
        self.candidates = candidates
        (stream, continuation) = AsyncStream.makeStream(of: Void.self)
    }

    func discoverLiveMacs() async -> [MobileDiscoveredIrohMac] { candidates }
    func directoryUpdates() -> AsyncStream<Void> { stream }
    func setCandidates(_ candidates: [MobileDiscoveredIrohMac]) { self.candidates = candidates }
    func emitUpdate() { continuation.yield(()) }
    func invalidateDiscovery(forMacDeviceID _: String) async {}
}
