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

        /// How many frames the host sent that contain `needle`, now.
        func sentCount(containing needle: String) -> Int { state.withLock { $0.sent.filter { $0.contains(needle) }.count } }

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

    static func intent(option: String, permission: String = "p1", answers: [String: Any]? = nil,
                       annotations: [String: Any]? = nil) -> AgentPaneGestureIntent? {
        var params: [String: Any] = ["sessionId": "s", "permissionId": permission, "optionId": option]
        params["answers"] = answers
        params["annotations"] = annotations
        return AgentPaneGestureIntent(gestureParams: ["intent": ["method": "_acpmux/permission_respond", "params": params]])
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

    static func pendingQuestion() -> String {
        #"{"jsonrpc":"2.0","method":"_acpmux/permission_pending","params":{"sessionId":"s","permissionId":"p1","decisionNonce":"\#(nonce)","personInstance":"\#(instance)","request":{"options":[{"optionId":"yes","kind":"allow_once"},{"optionId":"no","kind":"reject_once"}],"toolCall":{"_meta":{"acpmux":{"question":{"items":[{"id":"q1","prompt":"Which one?"}]}}}}}}}"#
    }

    /// Leo 2026-10-21: an agent's question answered in the pane for a chat on another machine was
    /// refused there as "accepted only from the cmux app". The answer's proof covers its answers
    /// (acpmux `decision_answers_proof`), so that machine counts it as the person's.
    @Test func anAnswerToAnotherMachinesQuestionCarriesTheProofOverItsAnswers() async throws {
        let machine = "machine-\(UUID().uuidString)"
        let key = try #require(AcpmuxSecretKey())
        AcpmuxRemotePersonKeys.shared.bind(machine: machine, instance: Self.instance, key: key)
        defer { AcpmuxRemotePersonKeys.shared.drop(machine: machine) }
        let approvals = AgentPaneRemoteApprovals(machineID: machine, label: "host") { nil }
        let wire = RemoteWire()
        let route = AgentPaneRemoteRoute(machine: "host", approvals: approvals) { wire }
        let inbox = PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let id = try await transport.open(.remote(route))
        _ = await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#])
        _ = await inbox.frame(containing: "\"origin\":\"remote\"")
        transport.sessions.add("s")
        wire.push(Self.pendingQuestion())
        _ = await inbox.frame(containing: "permission_pending")

        transport.gestures.record(click: true)
        let intentB = try #require(Self.intent(option: "yes", answers: ["Which one?": "B"]))
        let ticket = try #require(transport.reserveGesture(intentB))
        let answer = #"{"jsonrpc":"2.0","id":7,"method":"_acpmux/permission_respond","params":{"sessionId":"s","permissionId":"p1","optionId":"yes","answers":{"Which one?":"B"},"_meta":{"cmuxGesture":"\#(ticket)"}}}"#
        let error = await transport.send(connection: id, frames: [answer])
        #expect(error == nil, "\(String(describing: error))")
        let sent = await wire.sent(containing: "permission_respond")
        let object = try JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any]
        let params = try #require(object?["params"] as? [String: Any])
        let acpmux = (params["_meta"] as? [String: Any])?["acpmux"] as? [String: Any]
        #expect(acpmux?["decisionNonce"] as? String == Self.nonce)
        let expected = key.decisionProof(instance: Self.instance, session: "s", permission: "p1", option: "yes", nonce: Self.nonce,
                                         answers: ["Which one?": "B"])
        #expect(expected != nil)
        #expect(acpmux?["personDecision"] as? String == expected, "the answer went without the proof over its answers: \(sent)")
        #expect(acpmux?["personDecision"] as? String
            != key.decisionProof(instance: Self.instance, session: "s", permission: "p1", option: "yes", nonce: Self.nonce))
    }

    /// The same bytes acpmux checks (`the_answers_decision_proof_matches_the_apps_vector` in
    /// cmux-tui/crates/acpmux/tests/person_allow.rs): key order by UTF-8 bytes, acpmux's escapes.
    @Test func theAnswersProofMatchesAcpmuxsVector() throws {
        let key = try #require(AcpmuxSecretKey(hex: "5e1f0c2a9b8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f"))
        let answers = try JSONSerialization.jsonObject(
            with: Data(#"{"Which one?":"B","Pick a color\n(one)":["red","blue"],"é":"\u0001"}"#.utf8))
        #expect(AcpmuxSecretKey.canonicalJSON(answers) == "{\"Pick a color\\n(one)\":[\"red\",\"blue\"],\"Which one?\":\"B\",\"é\":\"\\u0001\"}")
        #expect(key.decisionProof(instance: "0123456789abcdef", session: "sess-1", permission: "perm-1", option: "allow_once",
                                  nonce: "nonce-1", answers: answers)
            == "3b11c2af201d95772c106a4c8463a54b94e615f85e88eac0700f7d657c24f0e9")
        // With annotations (a preview with a line break and a character past the BMP).
        let annotations = try JSONSerialization.jsonObject(
            with: Data(#"{"Which one?":{"preview":"[ B ]\n\ud83d\ude00","notes":"n"}}"#.utf8))
        #expect(AcpmuxSecretKey.canonicalJSON(annotations) == "{\"Which one?\":{\"notes\":\"n\",\"preview\":\"[ B ]\\n\u{1F600}\"}}")
        #expect(key.decisionProof(instance: "0123456789abcdef", session: "sess-1", permission: "perm-1", option: "allow_once",
                                  nonce: "nonce-1", answers: answers, annotations: annotations)
            == "03512f50a44821e899adf320ffd8babf9fc9a34c105e62b4861103c901da6992")
    }

    /// Codex review of #25424: the ticket binds the answers and annotations the person picked, by
    /// their canonical JSON, so a ticket taken for one answer never redeems (nor gets signed for)
    /// another, nested Codex answers and annotations included.
    @Test func aTicketIsForExactlyItsAnswersAndAnnotations() throws {
        let codexB: [String: Any] = ["q1": ["answers": ["B"]]]
        let notes: [String: Any] = ["Which one?": ["preview": "[ B ]", "notes": "n"]]
        let intent = try #require(Self.intent(option: "yes", answers: codexB, annotations: notes))
        func frame(_ answers: Any?, _ annotations: Any? = nil) -> [String: Any] {
            var params: [String: Any] = ["sessionId": "s", "permissionId": "p1", "optionId": "yes", "_meta": ["cmuxGesture": "t"]]
            params["answers"] = answers
            params["annotations"] = annotations
            return params
        }
        let method = "_acpmux/permission_respond"
        // Key order does not matter: the canonical JSON is the same.
        #expect(intent.matches(method: method, params: frame(["q1": ["answers": ["B"]]], ["Which one?": ["notes": "n", "preview": "[ B ]"]])))
        #expect(!intent.matches(method: method, params: frame(["q1": ["answers": ["A"]]], notes)))
        #expect(!intent.matches(method: method, params: frame(codexB, ["Which one?": ["preview": "[ B ]", "notes": "m"]])))
        #expect(!intent.matches(method: method, params: frame(codexB)))
        #expect(!intent.matches(method: method, params: frame(nil)))
        // Codex review, round 2: canonically equivalent Unicode is not the same answer (a
        // composed and a decomposed é can name two files on that machine), in answers and notes.
        let composed = try #require(Self.intent(option: "yes", answers: ["Path?": "/tmp/caf\u{E9}"],
                                                annotations: ["Path?": ["notes": "caf\u{E9}"]]))
        #expect(composed.matches(method: method, params: frame(["Path?": "/tmp/caf\u{E9}"], ["Path?": ["notes": "caf\u{E9}"]])))
        #expect(!composed.matches(method: method, params: frame(["Path?": "/tmp/cafe\u{301}"], ["Path?": ["notes": "caf\u{E9}"]])))
        #expect(!composed.matches(method: method, params: frame(["Path?": "/tmp/caf\u{E9}"], ["Path?": ["notes": "cafe\u{301}"]])))
        // A ticket without answers never redeems an answer that has some.
        let plain = try #require(Self.intent(option: "yes"))
        #expect(plain.matches(method: method, params: frame(nil)))
        #expect(!plain.matches(method: method, params: frame(codexB)))
        // Answers in an intent are objects; anything else breaks the contract.
        #expect(AgentPaneGestureIntent(gestureParams: ["intent": ["method": method, "params": [
            "sessionId": "s", "permissionId": "p1", "optionId": "yes", "answers": "B"]]]) == nil)
        #expect(AgentPaneGestureIntent(gestureParams: ["intent": ["method": "session/set_mode", "params": [
            "modeId": "m", "answers": ["q": "B"]]]]) == nil)
    }

    /// The same review, through the transport: a ticket the page took for answer B does not let
    /// it send answer A to another machine (the gesture is refused, so nothing is signed).
    @Test func aTicketForOneAnswerIsRefusedForAnother() async throws {
        let machine = "machine-\(UUID().uuidString)"
        let key = try #require(AcpmuxSecretKey())
        AcpmuxRemotePersonKeys.shared.bind(machine: machine, instance: Self.instance, key: key)
        defer { AcpmuxRemotePersonKeys.shared.drop(machine: machine) }
        let approvals = AgentPaneRemoteApprovals(machineID: machine, label: "host") { nil }
        let wire = RemoteWire()
        let route = AgentPaneRemoteRoute(machine: "host", approvals: approvals) { wire }
        let inbox = PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let id = try await transport.open(.remote(route))
        _ = await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#])
        _ = await inbox.frame(containing: "\"origin\":\"remote\"")
        transport.sessions.add("s")
        wire.push(Self.pendingQuestion())
        _ = await inbox.frame(containing: "permission_pending")

        transport.gestures.record(click: true)
        let intentB = try #require(Self.intent(option: "yes", answers: ["Which one?": "B"]))
        let ticket = try #require(transport.reserveGesture(intentB))
        let swapped = #"{"jsonrpc":"2.0","id":7,"method":"_acpmux/permission_respond","params":{"sessionId":"s","permissionId":"p1","optionId":"yes","answers":{"Which one?":"A"},"_meta":{"cmuxGesture":"\#(ticket)"}}}"#
        #expect(await transport.send(connection: id, frames: [swapped]) == .gestureRequired)

        // A composed é in the ticket, a decomposed one in the frame: canonically equivalent, but
        // other bytes, so refused too (Codex review, round 2).
        transport.gestures.record(click: true)
        let intentCafe = try #require(Self.intent(option: "yes", answers: ["Which one?": "caf\u{E9}"]))
        let cafe = try #require(transport.reserveGesture(intentCafe))
        let decomposed = #"{"jsonrpc":"2.0","id":8,"method":"_acpmux/permission_respond","params":{"sessionId":"s","permissionId":"p1","optionId":"yes","answers":{"Which one?":"cafe\u0301"},"_meta":{"cmuxGesture":"\#(cafe)"}}}"#
        #expect(await transport.send(connection: id, frames: [decomposed]) == .gestureRequired)
        #expect(wire.sentCount(containing: "permission_respond") == 0, "a swapped answer went out")
    }
}
