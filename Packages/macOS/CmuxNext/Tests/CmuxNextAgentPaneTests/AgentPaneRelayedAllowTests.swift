import Foundation
import CmuxNextCompat
import Testing
@testable import CmuxNextAgentPane

/// cx-0q7o slice 2c, at the relay boundary (the page's frames into ``AgentPaneTransport``, out to
/// acpmux): a click on Allow takes a ticket for that prompt and option and the answer goes out,
/// on a local daemon (the acpmux WebSocket stand-in) and on another machine's (a remote wire).
/// There, with the machine's key bound to the asking run, the answer carries the person's
/// decision proof; without a ticket it carries none and the pane says approvals are off.
@Suite(.serialized)
@MainActor
struct AgentPaneRelayedAllowTests {
    static let nonce = String(repeating: "ab", count: 32)
    static let instance = String(repeating: "c", count: 32)

    /// What the page received, awaited as it arrives (never on a timer).
    final class PageInbox: @unchecked Sendable { // crash-allow: test support; every access holds the lock
        private let state = Mutex<(frames: [String], waiters: [(String, CheckedContinuation<String, Never>)])>(([], []))

        func deliver(_ frames: [String]) {
            let ready = state.withLock { state -> [(CheckedContinuation<String, Never>, String)] in
                state.frames += frames
                var ready: [(CheckedContinuation<String, Never>, String)] = []
                state.waiters.removeAll { needle, waiter in
                    guard let frame = state.frames.first(where: { $0.contains(needle) }) else { return false }
                    ready.append((waiter, frame))
                    return true
                }
                return ready
            }
            for (waiter, frame) in ready { waiter.resume(returning: frame) }
        }

        /// The first frame that contains `needle`.
        func frame(containing needle: String) async -> String {
            await withCheckedContinuation { waiter in
                let found = state.withLock { state -> String? in
                    if let frame = state.frames.first(where: { $0.contains(needle) }) { return frame }
                    state.waiters.append((needle, waiter))
                    return nil
                }
                if let found { waiter.resume(returning: found) }
            }
        }
    }

    /// Another machine's acpmux behind the owning session daemon: answers each request at once,
    /// pushes what the test sends, and hands each frame the host sent to `sent`.
    final class RemoteWire: AcpmuxPaneWire, @unchecked Sendable { // crash-allow: test support; every access holds the lock
        private let state = Mutex<(onFrame: (@Sendable (String) -> Void)?, sent: [String], waiters: [(String, CheckedContinuation<String, Never>)])>((nil, [], []))

        func open(onFrame: @escaping @Sendable (String) -> Void, onClose: @escaping @Sendable (Int, String) -> Void) async throws {
            state.withLock { $0.onFrame = onFrame }
        }

        func send(_ text: String, completion: @escaping @Sendable (Bool) -> Void) {
            let (push, ready) = state.withLock { state -> ((@Sendable (String) -> Void)?, [(CheckedContinuation<String, Never>, String)]) in
                state.sent.append(text)
                var ready: [(CheckedContinuation<String, Never>, String)] = []
                state.waiters.removeAll { needle, waiter in
                    guard text.contains(needle) else { return false }
                    ready.append((waiter, text))
                    return true
                }
                return (state.onFrame, ready)
            }
            completion(true)
            for (waiter, frame) in ready { waiter.resume(returning: frame) }
            guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                  let id = object["id"] as? Int, let method = object["method"] as? String else { return }
            let result = method == "initialize" ? #"{"protocolVersion":1,"_meta":{"acpmux":{"origin":"remote"}}}"# : "{}"
            push?(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#)
        }

        func cancel(code: Int, reason: String) {}

        func push(_ text: String) { state.withLock { $0.onFrame }?(text) }

        /// The first frame the host sent that contains `needle`.
        func sent(containing needle: String) async -> String {
            await withCheckedContinuation { waiter in
                let found = state.withLock { state -> String? in
                    if let frame = state.sent.first(where: { $0.contains(needle) }) { return frame }
                    state.waiters.append((needle, waiter))
                    return nil
                }
                if let found { waiter.resume(returning: found) }
            }
        }
    }

    static func pending(instance: String = instance) -> String {
        #"{"jsonrpc":"2.0","method":"_acpmux/permission_pending","params":{"sessionId":"s","permissionId":"p1","decisionNonce":"\#(nonce)","personInstance":"\#(instance)","request":{"options":[{"optionId":"yes","kind":"allow_once"},{"optionId":"no","kind":"reject_once"}]}}}"#
    }

    static func allow(ticket: String?) -> String {
        let meta = ticket.map { #","_meta":{"cmuxGesture":"\#($0)"}"# } ?? ""
        return #"{"jsonrpc":"2.0","id":7,"method":"_acpmux/permission_respond","params":{"sessionId":"s","permissionId":"p1","optionId":"yes"\#(meta)}}"#
    }

    static func intent(option: String, permission: String = "p1") -> AgentPaneGestureIntent? {
        AgentPaneGestureIntent(gestureParams: ["intent": ["method": "_acpmux/permission_respond",
                                                          "params": ["sessionId": "s", "permissionId": permission, "optionId": option]]])
    }

    @Test func aClickOnAllowCountsOnTheLocalDaemon() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        // The local daemon's own run: its prompts need no relayed proof.
        server.answer("initialize", with: #"{"protocolVersion":1,"_meta":{"acpmux":{"origin":"local","personInstance":"\#(Self.instance)"}}}"#)
        let inbox = PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        var bannerShown = false
        transport.onRemoteApprovalsOff = { _ in bannerShown = true }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        _ = await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#])
        _ = await inbox.frame(containing: "\"origin\":\"local\"")
        transport.sessions.add("s")
        server.push(Self.pending(), to: 0)
        _ = await inbox.frame(containing: "permission_pending")

        // A ticket only for an option the prompt offers as an allow, of a prompt the pane saw.
        transport.gestures.record(click: true)
        let deny = try #require(Self.intent(option: "no"))
        let unseen = try #require(Self.intent(option: "yes", permission: "p-unseen"))
        let allow = try #require(Self.intent(option: "yes"))
        #expect(transport.reserveGesture(deny) == nil)
        #expect(transport.reserveGesture(unseen) == nil)
        let ticket = try #require(transport.reserveGesture(allow))
        let error = await transport.send(connection: id, frames: [Self.allow(ticket: ticket)])
        #expect(error == nil, "\(String(describing: error))")
        _ = await inbox.frame(containing: "\"id\":7")
        let sent = try #require(server.peers.first?.frames.first { $0.contains("permission_respond") })
        let object = try JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any]
        let params = try #require(object?["params"] as? [String: Any])
        #expect(params["optionId"] as? String == "yes")
        #expect(params["_meta"] == nil, "the ticket reached acpmux, or a proof went to the daemon's own prompt: \(sent)")
        #expect(!bannerShown)
    }

    @Test func aClickOnAllowCarriesTheProofToAnotherMachineOnlyWithItsTicket() async throws {
        let machine = "machine-\(UUID().uuidString)"
        let key = try #require(AcpmuxSecretKey())
        AcpmuxRemotePersonKeys.shared.bind(machine: machine, instance: Self.instance, key: key)
        defer { AcpmuxRemotePersonKeys.shared.drop(machine: machine) }
        let approvals = AgentPaneRemoteApprovals(machineID: machine, label: "host") { nil }

        // A bound key with the ticket: the proof. A bound key without one: no proof and no notice
        // (approvals are on). No key bound for that machine and run: no proof, and the notice.
        for (withTicket, keyBound) in [(true, true), (false, true), (true, false)] {
            if !keyBound { AcpmuxRemotePersonKeys.shared.drop(machine: machine) }
            let wire = RemoteWire()
            let route = AgentPaneRemoteRoute(machine: "host", approvals: approvals) { wire }
            let inbox = PageInbox()
            let transport = AgentPaneTransport()
            transport.deliver = { event, done in inbox.deliver(event.frames); done() }
            var bannerShown = false
            transport.onRemoteApprovalsOff = { _ in bannerShown = true }
            let id = try await transport.open(.remote(route))
            _ = await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#])
            _ = await inbox.frame(containing: "\"origin\":\"remote\"")
            transport.sessions.add("s")
            wire.push(Self.pending())
            _ = await inbox.frame(containing: "permission_pending")

            transport.gestures.record(click: true)
            let allow = try #require(Self.intent(option: "yes"))
            let reserved = withTicket ? transport.reserveGesture(allow) : nil
            if withTicket { #expect(reserved != nil, "no ticket for a seen prompt's allow option") }
            let ticket = reserved
            let error = await transport.send(connection: id, frames: [Self.allow(ticket: ticket)])
            #expect(error == nil, "\(String(describing: error))")
            let sent = await wire.sent(containing: "permission_respond")
            let object = try JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any]
            let params = try #require(object?["params"] as? [String: Any])
            let acpmux = (params["_meta"] as? [String: Any])?["acpmux"] as? [String: Any]
            #expect((params["_meta"] as? [String: Any])?["cmuxGesture"] == nil, "the ticket reached the wire: \(sent)")
            if withTicket && keyBound {
                #expect(acpmux?["decisionNonce"] as? String == Self.nonce)
                #expect(acpmux?["personDecision"] as? String
                    == key.decisionProof(instance: Self.instance, session: "s", permission: "p1", option: "yes", nonce: Self.nonce))
                #expect(!bannerShown)
            } else {
                #expect(acpmux == nil, "an allow without the person's ticket or key carried a proof: \(sent)")
                #expect(bannerShown == !keyBound)
            }
        }
    }
}
