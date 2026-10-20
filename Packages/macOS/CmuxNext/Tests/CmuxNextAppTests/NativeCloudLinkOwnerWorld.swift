import Foundation
@testable import CmuxNextCloud

actor NativeCloudLinkOwnerWorld {
    let started = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(8))
    let stopping = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(8))
    private(set) var events: [String] = []
    private(set) var made: [String] = []
    private var holdStart = false
    private var holdStop = false
    private var starts: [String: CheckedContinuation<Void, Never>] = [:]
    private var stops: [String: CheckedContinuation<Void, Never>] = [:]

    func holdStartupAndStop() { holdStart = true; holdStop = true }
    func make(_ scope: CloudTeamScope.Snapshot) -> NativeCloudLinkLease {
        let tag = String(scope.id.prefix(12))
        made.append(scope.team)
        return NativeCloudLinkLease(child: NativeCloudLinkOwnerChild(tag: tag, world: self),
            stop: { await self.note("enrollment-stop:\(tag)") }, revoke: { await self.note("revoke:\(tag)") })
    }
    func note(_ event: String) { events.append(event) }
    func start(_ tag: String) async {
        events.append("start:\(tag)")
        if holdStart {
            await withCheckedContinuation { starts[tag] = $0; started.continuation.yield(tag) }
        }
    }
    func stop(_ tag: String) async {
        events.append("stop-start:\(tag)")
        starts.removeValue(forKey: tag)?.resume()
        if holdStop {
            await withCheckedContinuation { stops[tag] = $0; stopping.continuation.yield(tag) }
        }
        events.append("stop-finish:\(tag)")
    }
    func finishStop(_ tag: String) { stops.removeValue(forKey: tag)?.resume() }
}
