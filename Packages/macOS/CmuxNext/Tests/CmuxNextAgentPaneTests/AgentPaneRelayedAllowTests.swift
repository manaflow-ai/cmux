import Foundation
import CmuxNextCompat
import CryptoKit
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

    /// A prompt of a peer of this Mac's daemon (a chat opened with `--host`): another daemon run
    /// than the one this connection talks to, on the local WebSocket.
    static func peerPending() -> String {
        #"{"jsonrpc":"2.0","method":"_acpmux/permission_pending","params":{"sessionId":"s","permissionId":"p1","decisionNonce":"\#(nonce)","personInstance":"\#(instance)","peer":"far","via":"peer","request":{"toolCall":{"toolCallId":"call-1","kind":"execute"},"options":[{"optionId":"yes","kind":"allow_once"},{"optionId":"always","kind":"allow_always"},{"optionId":"no","kind":"reject_once"}]}}}"#
    }

    /// The local daemon's own run (not the peer's) and a peer's prompt, seen by the page.
    static func peerChat(_ server: AcpmuxStandInServer, _ inbox: PageInbox, _ transport: AgentPaneTransport) async throws -> Int {
        // A DEV build's memory key (the app makes its approver at launch and hands it to each pane).
        transport.peerApprover = AgentPanePeerApprover(key: AcpmuxMacApprover(keychainService: nil))
        let local = String(repeating: "d", count: 32)
        server.answer("initialize", with: #"{"protocolVersion":1,"_meta":{"acpmux":{"origin":"local","personInstance":"\#(local)"}}}"#)
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        _ = await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#])
        _ = await inbox.frame(containing: "\"origin\":\"local\"")
        transport.sessions.add("s")
        server.push(Self.peerPending(), to: 0)
        _ = await inbox.frame(containing: "permission_pending")
        return id
    }

    /// Peer-route approvals: Allow on a peer's prompt goes out signed by this Mac's approver key,
    /// over that prompt, its tool call and the option picked; the "Remote approvals are off"
    /// notice no longer shows. An always-allow goes unsigned, and the pane says only a one-time
    /// allow works from this Mac.
    @Test func anAllowForAPeersPromptCarriesThisMacsSignedOneTimeAllow() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let inbox = PageInbox()
        let transport = AgentPaneTransport()
        var remoteOff = false
        var peerOff: [AgentPanePeerApprovals?] = []
        transport.onRemoteApprovalsOff = { _ in remoteOff = true }
        transport.onPeerApprovalsOff = { peerOff.append($0) }
        let id = try await Self.peerChat(server, inbox, transport)

        transport.gestures.record(click: true)
        let ticketIntent = try #require(Self.intent(option: "yes"))
        let ticket = try #require(transport.reserveGesture(ticketIntent))
        let before = UInt64(Date().timeIntervalSince1970)
        #expect(await transport.send(connection: id, frames: [Self.allow(ticket: ticket)]) == nil)
        _ = await inbox.frame(containing: "\"id\":7")
        let sent = try #require(server.peers.first?.frames.first { $0.contains("permission_respond") })
        let params = try #require((try JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any])?["params"] as? [String: Any])
        let acpmux = try #require((params["_meta"] as? [String: Any])?["acpmux"] as? [String: Any], "an unsigned allow: \(sent)")
        #expect(acpmux["decisionNonce"] as? String == Self.nonce)
        #expect(acpmux["personDecision"] == nil)
        let decision = try #require(acpmux["approverDecision"] as? [String: Any])
        let identity = try #require(transport.peerApprover?.key.identity)
        #expect(decision["approver"] as? String == identity.id)
        let expires = try #require((decision["expiresAt"] as? NSNumber)?.uint64Value)
        #expect(expires > before && expires <= before + 300)
        let key = try P256.Signing.PublicKey(x963Representation: AcpmuxMacApproverTests.bytes(identity.publicKey))
        let signature = try P256.Signing.ECDSASignature(
            rawRepresentation: AcpmuxMacApproverTests.bytes(try #require(decision["signature"] as? String)))
        let message = AcpmuxMacApprover.message(instance: Self.instance, mac: identity.id, session: "s", permission: "p1",
                                                toolCall: "call-1", option: "yes", nonce: Self.nonce, expiresAt: expires, answers: "")
        #expect(key.isValidSignature(signature, for: message))
        // It counted: nothing to say (nil ends any peer notice).
        #expect(!remoteOff && peerOff == [nil])

        // An always-allow: no signature, and the pane says only a one-time allow works. The
        // peer's refusal of that unsigned allow is not for want of enrolling this Mac.
        server.setAnswers(false)
        transport.gestures.record(click: true)
        let alwaysIntent = try #require(Self.intent(option: "always"))
        let always = try #require(transport.reserveGesture(alwaysIntent))
        let alwaysFrame = Self.allow(ticket: always).replacingOccurrences(of: #""id":7"#, with: #""id":8"#)
            .replacingOccurrences(of: #""optionId":"yes""#, with: #""optionId":"always""#)
        #expect(await transport.send(connection: id, frames: [alwaysFrame]) == nil)
        #expect(await server.wait { $0.first?.frames.contains { $0.contains(#""always""#) } == true })
        let sentAlways = try #require(server.peers.first?.frames.last { $0.contains("permission_respond") })
        #expect(!sentAlways.contains("approverDecision"), "an always-allow was signed: \(sentAlways)")
        let alwaysID = try #require((try JSONSerialization.jsonObject(with: Data(sentAlways.utf8)) as? [String: Any])?["id"] as? Int)
        server.push(#"{"jsonrpc":"2.0","id":\#(alwaysID),"error":{"code":-32000,"message":"approve this on the Mac app","data":{"reason":"permission.person_required","peer":"far"}}}"#, to: 0)
        _ = await inbox.frame(containing: "person_required")
        #expect(peerOff == [nil, .onceOnly])
        #expect(!remoteOff)
    }

    /// A peer that has not enrolled this Mac refuses the allow, naming itself (acpmux
    /// `permission.person_required` with `data.peer`): the pane offers to enroll this Mac there,
    /// by that peer's name, instead of "Remote approvals are off".
    @Test func aPeersRefusalOffersToEnrollThisMacThere() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let inbox = PageInbox()
        let transport = AgentPaneTransport()
        var remoteOff = false
        var peerOff: [AgentPanePeerApprovals?] = []
        transport.onRemoteApprovalsOff = { _ in remoteOff = true }
        transport.onPeerApprovalsOff = { peerOff.append($0) }
        let id = try await Self.peerChat(server, inbox, transport)
        server.setAnswers(false)

        transport.gestures.record(click: true)
        let ticketIntent = try #require(Self.intent(option: "yes"))
        let ticket = try #require(transport.reserveGesture(ticketIntent))
        #expect(await transport.send(connection: id, frames: [Self.allow(ticket: ticket)]) == nil)
        #expect(await server.wait { $0.first?.frames.contains { $0.contains("permission_respond") } == true })
        let sent = try #require(server.peers.first?.frames.first { $0.contains("permission_respond") })
        let relayID = try #require((try JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any])?["id"] as? Int)
        #expect(!remoteOff && peerOff.isEmpty, "a notice showed before the peer refused")
        server.push(#"{"jsonrpc":"2.0","id":\#(relayID),"error":{"code":-32000,"message":"approve this on the Mac app","data":{"reason":"permission.person_required","peer":"far"}}}"#, to: 0)
        _ = await inbox.frame(containing: "person_required")
        #expect(peerOff == [.notEnrolled(peer: "far")])
        #expect(!remoteOff)
    }

    /// The relay id of the newest `method` frame the stand-in got.
    static func relayID(_ server: AcpmuxStandInServer, _ method: String, after count: Int) async throws -> Int {
        #expect(await server.wait { ($0.first?.frames.filter { $0.contains(method) }.count ?? 0) > count })
        let sent = try #require(server.peers.first?.frames.last { $0.contains(method) })
        return try #require((try JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any])?["id"] as? Int)
    }

    static func refusal(_ id: Int, peer: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32000,"message":"approve this on the Mac app","data":{"reason":"permission.person_required","peer":"\#(peer)"}}}"#
    }

    /// An Allow that went out without this Mac's signature (here: a click with no ticket for that
    /// pick; also a key that could not sign, or a prompt that changed while it signed) is refused
    /// by the peer, but enrolling this Mac there would not help: the pane offers no Enroll.
    @Test func anUnsignedAllowsRefusalOffersNoEnroll() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let inbox = PageInbox()
        let transport = AgentPaneTransport()
        var peerOff: [AgentPanePeerApprovals?] = []
        transport.onPeerApprovalsOff = { peerOff.append($0) }
        let id = try await Self.peerChat(server, inbox, transport)
        server.setAnswers(false)

        transport.gestures.record(click: true)
        #expect(await transport.send(connection: id, frames: [Self.allow(ticket: nil)]) == nil)
        let relayID = try await Self.relayID(server, "permission_respond", after: 0)
        let sent = try #require(server.peers.first?.frames.last { $0.contains("permission_respond") })
        #expect(!sent.contains("approverDecision"), "a pick without its ticket was signed: \(sent)")
        server.push(Self.refusal(relayID, peer: "far"), to: 0)
        _ = await inbox.frame(containing: "person_required")
        #expect(peerOff.isEmpty, "an unsigned allow's refusal offered to enroll: \(peerOff)")
    }

    /// Each reply is read against its own request: an unsigned answer that failed some other way
    /// leaves nothing behind, so a later signed Allow's refusal still offers to enroll this Mac,
    /// and replies that come back out of order name the right peer.
    @Test func eachRefusalIsReadAgainstItsOwnRequest() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let inbox = PageInbox()
        let transport = AgentPaneTransport()
        var peerOff: [AgentPanePeerApprovals?] = []
        transport.onPeerApprovalsOff = { peerOff.append($0) }
        let id = try await Self.peerChat(server, inbox, transport)
        server.setAnswers(false)

        // An always-allow (unsigned: "only a one-time Allow works"), refused for another reason.
        transport.gestures.record(click: true)
        let alwaysIntent = try #require(Self.intent(option: "always"))
        let always = try #require(transport.reserveGesture(alwaysIntent))
        let alwaysFrame = Self.allow(ticket: always).replacingOccurrences(of: #""optionId":"yes""#, with: #""optionId":"always""#)
        #expect(await transport.send(connection: id, frames: [alwaysFrame]) == nil)
        let first = try await Self.relayID(server, "permission_respond", after: 0)
        server.push(#"{"jsonrpc":"2.0","id":\#(first),"error":{"code":-32602,"message":"no such option"}}"#, to: 0)
        _ = await inbox.frame(containing: "no such option")
        #expect(peerOff == [.onceOnly])

        // A signed one-time Allow, refused for want of enrolling this Mac: the hint, though an
        // unsigned answer went before it.
        transport.gestures.record(click: true)
        let yesIntent = try #require(Self.intent(option: "yes"))
        let yes = try #require(transport.reserveGesture(yesIntent))
        let signed = Self.allow(ticket: yes).replacingOccurrences(of: #""id":7"#, with: #""id":8"#)
        #expect(await transport.send(connection: id, frames: [signed]) == nil)
        let second = try await Self.relayID(server, "permission_respond", after: 1)
        server.push(Self.refusal(second, peer: "far"), to: 0)
        _ = await inbox.frame(containing: #""id":8"#)
        #expect(peerOff == [.onceOnly, .notEnrolled(peer: "far")])

        // Out of order: a signed Allow and an unsigned one (no ticket) in flight together; the
        // unsigned one's refusal comes first, naming another peer, and says nothing.
        transport.gestures.record(click: true)
        let againIntent = try #require(Self.intent(option: "yes"))
        let again = try #require(transport.reserveGesture(againIntent))
        let signedAgain = Self.allow(ticket: again).replacingOccurrences(of: #""id":7"#, with: #""id":10"#)
        #expect(await transport.send(connection: id, frames: [signedAgain]) == nil)
        let third = try await Self.relayID(server, "permission_respond", after: 2)
        transport.gestures.record(click: true)
        let unsigned = Self.allow(ticket: nil).replacingOccurrences(of: #""id":7"#, with: #""id":9"#)
        #expect(await transport.send(connection: id, frames: [unsigned]) == nil)
        let fourth = try await Self.relayID(server, "permission_respond", after: 3)
        server.push(Self.refusal(fourth, peer: "near"), to: 0)
        _ = await inbox.frame(containing: #""id":9"#)
        server.push(Self.refusal(third, peer: "far"), to: 0)
        _ = await inbox.frame(containing: #""id":10"#)
        #expect(peerOff == [.onceOnly, .notEnrolled(peer: "far"), .notEnrolled(peer: "far")])
    }

    /// A second answer under the page id of one still in flight is refused before it goes, and
    /// changes nothing about the first: the signed Allow's refusal still offers to enroll.
    @Test func anAnswerRefusedBeforeItGoesLeavesTheSignedOnesHint() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let inbox = PageInbox()
        let transport = AgentPaneTransport()
        var peerOff: [AgentPanePeerApprovals?] = []
        transport.onPeerApprovalsOff = { peerOff.append($0) }
        let id = try await Self.peerChat(server, inbox, transport)
        server.setAnswers(false)

        transport.gestures.record(click: true)
        let yesIntent = try #require(Self.intent(option: "yes"))
        let yes = try #require(transport.reserveGesture(yesIntent))
        #expect(await transport.send(connection: id, frames: [Self.allow(ticket: yes)]) == nil)
        let signed = try await Self.relayID(server, "permission_respond", after: 0)
        // The same page id again, unsigned (no ticket), while the first is in flight: refused here.
        transport.gestures.record(click: true)
        _ = await transport.send(connection: id, frames: [Self.allow(ticket: nil)])
        #expect(server.peers.first?.frames.filter { $0.contains("permission_respond") }.count == 1)
        server.push(Self.refusal(signed, peer: "far"), to: 0)
        _ = await inbox.frame(containing: "person_required")
        #expect(peerOff == [.notEnrolled(peer: "far")])
    }

    /// The card's Allow for a batch of a peer's tool prompts (`_acpmux/permission_group_respond`),
    /// after the person's click: one signed one-time allow per pending member of the group the
    /// page read (two here), over that member's prompt, tool call, nonce and the option the group's
    /// Allow selects. Allow for this chat (a lasting grant) goes unsigned, and the pane says only a
    /// one-time Allow works.
    @Test func aGroupAllowForAPeersPromptsSignsEachMember() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let inbox = PageInbox()
        let transport = AgentPaneTransport()
        var remoteOff = false
        var peerOff: [AgentPanePeerApprovals?] = []
        transport.onRemoteApprovalsOff = { _ in remoteOff = true }
        transport.onPeerApprovalsOff = { peerOff.append($0) }
        let id = try await Self.peerChat(server, inbox, transport)
        // A second prompt of the peer's, with its own tool call, nonce and allow-once option.
        let nonce2 = String(repeating: "cd", count: 32)
        let request2 = #"{"toolCall":{"toolCallId":"call-2","kind":"edit"},"options":[{"optionId":"ok","kind":"allow_once"},{"optionId":"no","kind":"reject_once"}]}"#
        server.push(#"{"jsonrpc":"2.0","method":"_acpmux/permission_pending","params":{"sessionId":"s","permissionId":"p2","decisionNonce":"\#(nonce2)","personInstance":"\#(Self.instance)","peer":"far","via":"peer","request":\#(request2)}}"#, to: 0)
        _ = await inbox.frame(containing: "\"permissionId\":\"p2\"")
        let request = #"{"toolCall":{"toolCallId":"call-1","kind":"execute"},"options":[{"optionId":"yes","kind":"allow_once"},{"optionId":"always","kind":"allow_always"},{"optionId":"no","kind":"reject_once"}]}"#
        server.answer("_acpmux/permission_groups", with: #"{"groups":[{"groupId":"g1","sessionId":"s","revision":2,"state":"pending","items":[{"permissionId":"p1","state":"pending","request":\#(request)},{"permissionId":"p2","state":"pending","request":\#(request2)}],"decisions":["allow_once","deny"]}],"peer":"far"}"#)
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":9,"method":"_acpmux/permission_groups","params":{"sessionId":"s"}}"#]) == nil)
        _ = await inbox.frame(containing: "\"id\":9")

        transport.gestures.record(click: true)
        let respond = #"{"jsonrpc":"2.0","id":10,"method":"_acpmux/permission_group_respond","params":{"sessionId":"s","groupId":"g1","revision":2,"decisionKey":"k1","decision":"allow_once"}}"#
        let before = UInt64(Date().timeIntervalSince1970)
        #expect(await transport.send(connection: id, frames: [respond]) == nil)
        _ = await inbox.frame(containing: "\"id\":10")
        let sent = try #require(server.peers.first?.frames.first { $0.contains("permission_group_respond") })
        let params = try #require((try JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any])?["params"] as? [String: Any])
        let acpmux = try #require((params["_meta"] as? [String: Any])?["acpmux"] as? [String: Any], "an unsigned group allow: \(sent)")
        let members = try #require(acpmux["approverDecisions"] as? [String: Any])
        #expect(Set(members.keys) == ["p1", "p2"])
        let identity = try #require(transport.peerApprover?.key.identity)
        let key = try P256.Signing.PublicKey(x963Representation: AcpmuxMacApproverTests.bytes(identity.publicKey))
        for (permission, toolCall, option, nonce) in [("p1", "call-1", "yes", Self.nonce), ("p2", "call-2", "ok", nonce2)] {
            let member = try #require(members[permission] as? [String: Any])
            #expect(member["decisionNonce"] as? String == nonce)
            let decision = try #require(member["approverDecision"] as? [String: Any])
            #expect(decision["approver"] as? String == identity.id)
            let expires = try #require((decision["expiresAt"] as? NSNumber)?.uint64Value)
            #expect(expires > before && expires <= before + 300)
            let signature = try P256.Signing.ECDSASignature(
                rawRepresentation: AcpmuxMacApproverTests.bytes(try #require(decision["signature"] as? String)))
            let message = AcpmuxMacApprover.message(instance: Self.instance, mac: identity.id, session: "s", permission: permission,
                                                    toolCall: toolCall, option: option, nonce: nonce, expiresAt: expires, answers: "")
            #expect(key.isValidSignature(signature, for: message), "member \(permission)")
            // Each member's signature covers its own prompt only.
            let other = AcpmuxMacApprover.message(instance: Self.instance, mac: identity.id, session: "s", permission: permission,
                                                  toolCall: toolCall == "call-1" ? "call-2" : "call-1", option: option, nonce: nonce,
                                                  expiresAt: expires, answers: "")
            #expect(!key.isValidSignature(signature, for: other))
        }
        #expect(!remoteOff && peerOff == [nil])

        // Allow for this chat: no signature, and the pane says only a one-time allow works.
        server.setAnswers(false)
        transport.gestures.record(click: true)
        let chat = respond.replacingOccurrences(of: #""id":10"#, with: #""id":11"#)
            .replacingOccurrences(of: #""allow_once""#, with: #""allow_chat""#).replacingOccurrences(of: "k1", with: "k2")
        #expect(await transport.send(connection: id, frames: [chat]) == nil)
        #expect(await server.wait { $0.first?.frames.contains { $0.contains("allow_chat") } == true })
        let sentChat = try #require(server.peers.first?.frames.last { $0.contains("permission_group_respond") })
        #expect(!sentChat.contains("approverDecisions"), "a lasting grant was signed: \(sentChat)")
        #expect(peerOff == [nil, .onceOnly])
        #expect(!remoteOff)
    }
}
