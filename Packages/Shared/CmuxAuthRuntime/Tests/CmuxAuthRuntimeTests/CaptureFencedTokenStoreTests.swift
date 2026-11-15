import Foundation
import Testing
@testable import CmuxAuthRuntime

@Suite struct CaptureFencedTokenStoreTests {
    @Test func freezeJoinsMigrationReadBeforeRejectingLateWriter() async {
        let base = MigrationReadStore()
        let (events, observer) = AsyncStream<Void>.makeStream()
        let fenced = CaptureFencedTokenStore(base: base, admissionClosed: {
            observer.yield(())
            observer.finish()
        })
        await base.armRefreshRead()

        let read = Task { await fenced.getStoredRefreshToken() }
        await base.waitForRefreshRead()
        let freeze = Task { await fenced.freezeForCapture() }
        let admissionObserved = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in events { return true }
                return false
            }
            group.addTask {
                do { try await Task.sleep(for: .seconds(2)) } catch { return false }
                return false
            }
            let observed = await group.next() ?? false
            group.cancelAll()
            return observed
        }
        #expect(admissionObserved)
        // The earlier migration read is still parked. A getter arriving after
        // this causal admission event must not reach the backing store either.
        #expect(await fenced.getStoredAccessToken() == nil)

        await base.releaseRefreshRead()
        #expect(await read.value == "refresh")
        await freeze.value

        #expect(await base.idleWasCalledWhileReadParked() == false)
        await fenced.setTokens(accessToken: "late", refreshToken: "late")
        #expect(await base.writeCount == 1)
        #expect(await fenced.getStoredRefreshToken() == nil)
    }
}

private actor MigrationReadStore: StackAuthTokenStoreProtocol {
    private var access: String? = "stored-access"
    private var refresh: String? = "refresh"
    private var writes = 0
    private var gate = false
    private var parked = false
    private var parkWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var idleWhileParked = false

    func armRefreshRead() { gate = true }

    func waitForRefreshRead() async {
        if parked { return }
        await withCheckedContinuation { parkWaiters.append($0) }
    }

    func releaseRefreshRead() {
        gate = false
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func getStoredAccessToken() async -> String? { access }

    func getStoredRefreshToken() async -> String? {
        if gate {
            parked = true
            let waiters = parkWaiters
            parkWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        // ImportingTokenStore can settle a migrated pair during this read.
        writes += 1
        return refresh
    }

    func setTokens(accessToken: String?, refreshToken: String?) async {
        writes += 1
        access = accessToken
        refresh = refreshToken
    }

    func clearTokens() async {
        writes += 1
        access = nil
        refresh = nil
    }

    func compareAndSet(compareRefreshToken: String, newRefreshToken: String?, newAccessToken: String?) async {
        guard refresh == compareRefreshToken else { return }
        await setTokens(accessToken: newAccessToken, refreshToken: newRefreshToken)
    }

    func captureAwaitIdle() async {
        idleWhileParked = gate
    }

    func idleWasCalledWhileReadParked() -> Bool { idleWhileParked }
    var writeCount: Int { writes }
}
