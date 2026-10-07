import CmuxLinkTesting
import CmuxMobileHost
import CmuxMobileWire
import Foundation
import Testing

/// C5 additions (c5-workspaces.md section 2): `workspace.close`,
/// `workspace.read` and `workspace.preview.set`.
@Suite("Workspace close, read and previews")
struct WorkspaceOpsC5Tests {
    let state = FakeDaemon.sample
    let policy = MobileOpPolicy(hostID: "h_mac1")

    func rejection(_ op: String, _ params: [String: JSONValue]) -> String? {
        if case .failure(let rejection) = policy.evaluate(op: op, params: .object(params), state: state) { return rejection.code }
        return nil
    }

    @Test func closeAndReadAreScopedToThisHostsTree() throws {
        let close = policy.evaluate(op: "workspace.close", params: .object(["workspace": "ws_a1"]), state: state)
        #expect(try close.get() == .closeWorkspace(workspace: "ws_a1"))
        let read = policy.evaluate(op: "workspace.read", params: .object(["workspace": "ws_a1"]), state: state)
        #expect(try read.get() == .markWorkspaceRead(workspace: "ws_a1"))
        #expect(rejection("workspace.close", ["workspace": "ws_zz9"]) == "workspace.not_found")
        #expect(rejection("workspace.read", ["workspace": "other:ws_a1"]) == "validation.invalid")
        #expect(rejection("workspace.read", [:]) == "validation.invalid")
        #expect(rejection("workspace.close", ["workspace": "ws_a1", "force": true]) == "validation.invalid")
        #expect(rejection("workspace.close", ["workspace": "ws_a1", "command": "rm -rf ~"]) == "auth.forbidden")
        #expect(rejection("workspace.read", ["workspace": "ws_a1", "cwd": "/"]) == "auth.forbidden")
    }

    @Test func capsAreAdvertised() {
        let caps = MobileHostConfiguration.defaultCaps
        #expect(caps.contains("workspace.close") && caps.contains("workspace.read") && caps.contains("workspace.preview"))
    }

    @Test func previewOnlyChangeIsAPreviewSet() {
        var next = state
        next.workspaces[0].panes[0].tabs[0].preview = "Compiling"
        let changes = WorkspaceDiff(from: state, to: next).changes
        #expect(changes.map(\.op) == ["workspace.preview.set"])
        #expect(changes.first?.params == .object(["tab": "tab_t1", "preview": "Compiling"]))
        next.workspaces[0].panes[0].tabs[0].unread = 3
        #expect(WorkspaceDiff(from: state, to: next).changes.map(\.op) == ["workspace.status.set", "workspace.preview.set"])
    }

    @Test func previewsAreSanitized() {
        #expect(MobilePreview("\u{1B}[31mred\u{1B}[0m\nnext\tline\u{7}").text == "red next line")
        #expect(MobilePreview("   ").text == nil)
        #expect(MobilePreview(String(repeating: "x", count: 1000)).text?.count == MobilePreview.maxLength)
        #expect(MobilePreview(nil).text == nil)
        #expect(MobilePreview("\u{1B}]0;title\u{7}ok").text == "ok")
    }

    @Test func executorClosesAndMarksRead() async throws {
        let daemon = FakeDaemon()
        let owner = WorkspaceStreamOwner(hostID: "h_mac1", daemon: daemon, startSeq: 10)
        let executor = MobileOpExecutor(policy: policy, owner: owner, daemon: daemon, authorizer: AllowAllAuthorizer())
        let principal = MobileDevicePrincipal(install: "in_phone1", userID: "u_1", platform: "ios", appVersion: "1")
        await daemon.mutate { $0.workspaces[0].panes[0].tabs[0].unread = 4 }
        let read = await executor.execute(OpFrame(op: "workspace.read", params: .object(["workspace": "ws_a1"]),
                                                  idempotencyKey: "read-key-0001"), principal: principal)
        guard case .result = read.outcome else { Issue.record("read refused: \(read.outcome)"); return }
        #expect(await daemon.state.workspaces[0].panes[0].tabs[0].unread == 0)
        let close = await executor.execute(OpFrame(op: "workspace.close", params: .object(["workspace": "ws_a1"]),
                                                   idempotencyKey: "close-key-001"), principal: principal)
        guard case .result = close.outcome else { Issue.record("close refused"); return }
        #expect(await daemon.state.workspaces.isEmpty)
        let again = await executor.execute(OpFrame(op: "workspace.close", params: .object(["workspace": "ws_a1"]),
                                                   idempotencyKey: "close-key-001"), principal: principal)
        #expect(again.replayed)
        #expect(await daemon.ops == [.markWorkspaceRead(workspace: "ws_a1"), .closeWorkspace(workspace: "ws_a1")])
    }

    @Test func previewsAreThrottledPerTabWithATrailingFlush() async throws {
        let daemon = FakeDaemon()
        let clock = ManualClock()
        let owner = WorkspaceStreamOwner(hostID: "h_mac1", daemon: daemon, startSeq: 100, now: { Date(timeIntervalSince1970: 1000) },
                                         previewInterval: .seconds(1), clock: clock)
        var updates = try await owner.updates(afterSeq: nil).makeAsyncIterator()
        guard case .snapshot(let snapshot)? = await updates.next() else { Issue.record("no snapshot"); return }
        #expect(snapshot.epoch == owner.epoch)
        await daemon.mutate { $0.workspaces[0].panes[0].tabs[0].preview = "one\u{1B}[0m" }
        await owner.refresh()
        guard case .event(let first)? = await updates.next() else { Issue.record("no event"); return }
        #expect(first.op == "workspace.preview.set")
        #expect(first.params["preview"] == "one")
        #expect(first.epoch == owner.epoch)
        // Within the interval: held, one trailing flush scheduled.
        await daemon.mutate { $0.workspaces[0].panes[0].tabs[0].preview = "two" }
        await owner.refresh()
        await daemon.mutate { $0.workspaces[0].panes[0].tabs[0].preview = "three" }
        await owner.refresh()
        let published = try await owner.currentState()
        #expect(published.workspaces[0].panes[0].tabs[0].preview == "one")
        await clock.waitForSleepers(1)
        #expect(clock.sleeperCount == 1)
        clock.advance(by: .seconds(1))
        guard case .event(let trailing)? = await updates.next() else { Issue.record("no trailing event"); return }
        #expect(trailing.params["preview"] == "three")
        #expect(trailing.seq == first.seq + 1)
    }
}
