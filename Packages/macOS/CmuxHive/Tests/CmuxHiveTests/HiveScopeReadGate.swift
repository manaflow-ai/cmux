import Foundation
@testable import CmuxHive

/// Holds one captured account read while the authoritative account changes.
actor HiveScopeReadGate {
    private var scope: HiveAccountScope
    private var suspendNextRead = false
    private var pending: CheckedContinuation<HiveAccountScope, Never>?
    private var capturedScope: HiveAccountScope?
    let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

    init(scope: HiveAccountScope) { self.scope = scope }

    func read() async -> HiveAccountScope {
        guard suspendNextRead else { return scope }
        suspendNextRead = false
        capturedScope = scope
        return await withCheckedContinuation { continuation in
            pending = continuation
            started.continuation.yield(())
        }
    }

    func holdNextRead() { suspendNextRead = true }

    func changeScope(to scope: HiveAccountScope) { self.scope = scope }

    func finishCapturedRead() {
        guard let capturedScope else { return }
        pending?.resume(returning: capturedScope)
        pending = nil
        self.capturedScope = nil
    }
}
