import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileShellModel
import Foundation

@MainActor
final class PendingDirectoryDiscovery: MobileIrohMacDiscovering {
    private var requestCount = 0
    private var pending: [Int: CheckedContinuation<[MobileDiscoveredIrohMac], Never>] = [:]
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]

    func discoverLiveMacs() async -> [MobileDiscoveredIrohMac] {
        await withCheckedContinuation { continuation in
            requestCount += 1
            pending[requestCount] = continuation
            waiters.removeValue(forKey: requestCount)?.resume()
        }
    }

    func waitForRequest(_ number: Int) async {
        guard requestCount < number else { return }
        await withCheckedContinuation { waiters[number] = $0 }
    }

    func finish(_ number: Int, with candidates: [MobileDiscoveredIrohMac]) {
        pending.removeValue(forKey: number)?.resume(returning: candidates)
    }

    func invalidateDiscovery(forMacDeviceID _: String) async {}
}
