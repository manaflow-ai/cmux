import Foundation
import Testing
@testable import CmuxRemoteDaemon

@Suite("RemoteDaemonPendingCallRegistry")
struct RemoteDaemonPendingCallRegistryTests {
    @Test("register/resolve/wait delivers the response payload")
    func happyPath() {
        let registry = RemoteDaemonPendingCallRegistry()
        let call = registry.register()

        #expect(registry.resolve(id: call.id, payload: ["ok": true, "result": ["value": 7]]))

        guard case .response(let payload) = registry.wait(for: call, timeout: 1.0) else {
            Issue.record("expected .response")
            return
        }
        #expect(payload["ok"] as? Bool == true)
        #expect((payload["result"] as? [String: Any])?["value"] as? Int == 7)
    }

    @Test("failAll fails every pending call with the message")
    func failAllFailsPendingCalls() {
        let registry = RemoteDaemonPendingCallRegistry()
        let first = registry.register()
        let second = registry.register()

        registry.failAll("transport died")

        guard case .failure(let firstMessage) = registry.wait(for: first, timeout: 1.0) else {
            Issue.record("expected .failure for first call")
            return
        }
        guard case .failure(let secondMessage) = registry.wait(for: second, timeout: 1.0) else {
            Issue.record("expected .failure for second call")
            return
        }
        #expect(firstMessage == "transport died")
        #expect(secondMessage == "transport died")
    }

    @Test("failAll does not overwrite an already-resolved call")
    func failAllSkipsResolvedCalls() {
        let registry = RemoteDaemonPendingCallRegistry()
        let call = registry.register()
        #expect(registry.resolve(id: call.id, payload: ["ok": true]))

        registry.failAll("transport died")

        guard case .response(let payload) = registry.wait(for: call, timeout: 1.0) else {
            Issue.record("expected .response to survive failAll")
            return
        }
        #expect(payload["ok"] as? Bool == true)
    }

    @Test("wait timeout removes the call and returns .timedOut")
    func waitTimeoutRemovesCall() {
        let registry = RemoteDaemonPendingCallRegistry()
        let call = registry.register()

        guard case .timedOut = registry.wait(for: call, timeout: 0.05) else {
            Issue.record("expected .timedOut")
            return
        }
        // The timed-out call was removed, so a late response has nowhere to go.
        #expect(!registry.resolve(id: call.id, payload: ["ok": true]))
    }

    @Test("request ids increment per register")
    func idsIncrement() {
        let registry = RemoteDaemonPendingCallRegistry()
        #expect(registry.register().id == 1)
        #expect(registry.register().id == 2)
        #expect(registry.register().id == 3)
    }

    @Test("reset drops pending calls and restarts ids at 1")
    func resetRestartsIDs() {
        let registry = RemoteDaemonPendingCallRegistry()
        let stale = registry.register()
        _ = registry.register()

        registry.reset()

        #expect(!registry.resolve(id: stale.id, payload: ["ok": true]))
        #expect(registry.register().id == 1)
    }

    @Test("remove unregisters a call without signaling it")
    func removeUnregisters() {
        let registry = RemoteDaemonPendingCallRegistry()
        let call = registry.register()

        registry.remove(call)

        #expect(!registry.resolve(id: call.id, payload: ["ok": true]))
    }
}
