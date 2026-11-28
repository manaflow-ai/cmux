import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import Testing

/// A create the person's own gesture started goes straight to the Cloud API as the person, in one call; every other
/// create, and every Retry of a key first sent on the relay, stays on the relay and its approval. The server keeps
/// each key per caller, so a key never changes route: only a fresh key picks one.
@Suite struct CloudPersonCreateTests {
    // MARK: The route

    @Test func aFreshKeyOfThePersonsOwnCreateGoesDirect() {
        #expect(CloudMachineRequest().createRoute(personsOwnCreate: true, team: "team_a") == .direct)
    }

    @Test func anAgentsScriptsOrCLIsCreateNeverGoesDirect() {
        // Not the person's own gesture (an agent, a script, the CLI, a socket run, an agent's card nobody clicked).
        #expect(CloudMachineRequest().createRoute(personsOwnCreate: false, team: "team_a") == .relay)
        var sent = CloudMachineRequest()
        sent.wasSent = true
        #expect(sent.createRoute(personsOwnCreate: false, team: "team_a") == .relay)
    }

    @Test func aRetriedRelayKeyNeverGoesDirect() {
        // Sent on the relay (its route kept), or sent, approved or being answered before routes were kept.
        var relayed = CloudMachineRequest()
        relayed.wasSent = true
        relayed.route = .relay
        var legacy = CloudMachineRequest()
        legacy.wasSent = true
        var approved = CloudMachineRequest()
        approved.approvedRequest = "apr_1"
        var answering = CloudMachineRequest()
        answering.answeringRequest = "apr_2"
        for request in [relayed, legacy, approved, answering] {
            #expect(request.createRoute(personsOwnCreate: true, team: "team_a") == .relay)
        }
    }

    @Test func aRetriedDirectKeyStaysDirect() {
        var direct = CloudMachineRequest()
        direct.wasSent = true
        direct.route = .direct
        #expect(direct.createRoute(personsOwnCreate: true, team: "team_a") == .direct)
        #expect(direct.createRoute(personsOwnCreate: false, team: "team_a") == .direct)
    }

    @Test func aNewKeyForgetsTheOldKeysRoute() {
        var request = CloudMachineRequest()
        request.route = .direct
        let same = request.idempotencyKey
        request.idempotencyKey = same
        #expect(request.route == .direct, "the same key kept its route")
        request.idempotencyKey = UUID().uuidString
        #expect(request.route == nil)
    }

    @Test func anEnvironmentBootOrAnUnknownTeamStaysOnTheRelay() {
        var boot = CloudMachineRequest()
        boot.environment = "env_1"
        #expect(boot.createRoute(personsOwnCreate: true, team: "team_a") == .relay)
        #expect(CloudMachineRequest().createRoute(personsOwnCreate: true, team: "") == .relay)
    }

    // MARK: A chat's start

    /// A start with a Cloud environment picked boots its machine in that environment, never a plain create the platform
    /// serves from the person's generic spare (staging probe run 45132397559: the picked chat ran on the spare, with none of
    /// the environment's variables or setup). Auto (nil) keeps the plain create, and with it the direct route.
    @Test func aStartWithAPickedEnvironmentBootsInItNotThePlainCreate() {
        let picked = CloudMachineRequest(startChatKey: "k", sizedFor: nil, team: "team_a", environment: "env_1")
        #expect(picked.environment == "env_1")
        #expect(!picked.takesPlainPath)
        #expect(picked.createRoute(personsOwnCreate: true, team: "team_a") == .relay)
        let auto = CloudMachineRequest(startChatKey: "k", sizedFor: nil, team: "team_a")
        #expect(auto.environment == nil)
        #expect(auto.createRoute(personsOwnCreate: true, team: "team_a") == .direct)
    }

    /// The start's plan as the ledger answers it (cmux-cloud-start-core's `StartChatPlan`, camelCase).
    private func plan(_ json: String) throws -> CloudMoveCLI.StartChatPlan {
        try JSONDecoder().decode(CloudMoveCLI.StartChatPlan.self, from: Data(json.utf8))
    }

    /// The route the app's create for a start takes, as `CloudStartChat` and `appServerCreate` pick it.
    private func route(_ plan: CloudMoveCLI.StartChatPlan, personsOwnRun: Bool, relayOnly: Bool = false) -> (key: String, route: CloudCreateRoute) {
        let request = CloudMachineRequest(startChatKey: plan.createKey, sizedFor: nil, team: "team_a", plan: plan)
        return (request.idempotencyKey, request.createRoute(personsOwnCreate: plan.ownCreate(personsOwnRun: personsOwnRun, relayOnly: relayOnly), team: "team_a"))
    }

    /// A chat the person started with the composer's Send is their own create: it goes as them, in one call, with no
    /// approval to hold, answer and wait out. It went over the relay (about 3 to 4 s of round trips, and a start that
    /// failed still pending).
    @Test func aChatThePersonStartedGoesDirect() throws {
        let fresh = try plan(#"{"createKey":"cloud-start-chat-k","tabKey":"t","keepsCreateRoute":true}"#)
        #expect(route(fresh, personsOwnRun: true).route == .direct)
        #expect(fresh.recorded(.direct) == .direct)
    }

    @Test func aChatAnAgentAScriptOrTheCLIStartedStaysOnTheRelay() throws {
        let fresh = try plan(#"{"createKey":"cloud-start-chat-k","tabKey":"t","keepsCreateRoute":true}"#)
        #expect(route(fresh, personsOwnRun: false).route == .relay)
        // The direct route refused this start before the op ran: its new key is the relay's.
        #expect(route(fresh, personsOwnRun: true, relayOnly: true).route == .relay)
    }

    /// A ledger that keeps no route (an older cmux-tui, or an app core that does not read it) could not tell a retry
    /// which route the key took, so the start never leaves the relay and names no route.
    @Test func aLedgerThatKeepsNoRouteNeverGoesDirect() throws {
        let old = try plan(#"{"createKey":"cloud-start-chat-k","tabKey":"t"}"#)
        #expect(!old.keepsCreateRoute)
        #expect(route(old, personsOwnRun: true).route == .relay)
        #expect(old.recorded(.relay) == nil && old.recorded(.direct) == nil)
    }

    /// The server keeps a key per caller, so a retry on the other route would be a second machine: a retry of a sent
    /// start sends the same key on the route the ledger kept, whoever retries it.
    @Test func aRetryOfAStartKeepsItsKeyAndItsRoute() throws {
        let direct = try plan(#"{"createKey":"cloud-start-chat-k","tabKey":"t","createSent":true,"createRoute":"direct","keepsCreateRoute":true}"#)
        let relayed = try plan(#"{"createKey":"cloud-start-chat-k","tabKey":"t","createSent":true,"createRoute":"relay","keepsCreateRoute":true}"#)
        // Sent before routes were kept, or on a route this app does not know: the relay.
        let legacy = try plan(#"{"createKey":"cloud-start-chat-k","tabKey":"t","createSent":true,"keepsCreateRoute":true}"#)
        let unknown = try plan(#"{"createKey":"cloud-start-chat-k","tabKey":"t","createSent":true,"createRoute":"carrier","keepsCreateRoute":true}"#)
        for person in [true, false] {
            #expect(route(direct, personsOwnRun: person) == (key: "cloud-start-chat-k", route: .direct))
            #expect(route(direct, personsOwnRun: person, relayOnly: true).route == .direct)
            for sent in [relayed, legacy, unknown] {
                #expect(route(sent, personsOwnRun: person) == (key: "cloud-start-chat-k", route: .relay))
            }
        }
        // A create that never went out has no route yet, whatever an earlier one recorded.
        let unsent = try plan(#"{"createKey":"cloud-start-chat-k2","tabKey":"t","createRoute":"direct","keepsCreateRoute":true}"#)
        #expect(CloudMachineRequest(startChatKey: unsent.createKey, sizedFor: nil, team: nil, plan: unsent).route == nil)
        #expect(route(unsent, personsOwnRun: false).route == .relay)
    }

    /// The server answers a person's create once the provider made the machine, or after 25 s with it provisioning.
    @Test func aDirectCreateWaitsPastTheServersOwnWait() {
        #expect(CloudPersonCreate.createTimeout > 25)
    }

    @Test func eachRouteMarksItsOwnStep() {
        #expect(CloudCreateRoute.direct.step == "machine.create.direct")
        #expect(CloudCreateRoute.relay.step == "machine.create.relay")
    }

    // MARK: The call

    @Test func theCallIsOneOpsPostAsTheUserOriginAfterTheEnsure() async throws {
        let seen = Seen()
        let ops = CloudPersonCreate.ops({ path, body in
            await seen.call(path, body)
            return Data(#"{"ok":true,"op":"cloud.machine.create","value":{"machine":{"id":"vm_1"}}}"#.utf8)
        }, after: { await seen.ensured() })
        let params = JSONValue.object(["name": .string("dev")])
        let answer = try await ops("cloud.machine.create", params, "key-1", .user)
        #expect(answer["machine"]?["id"]?.stringValue == "vm_1")
        let (calls, order) = await (seen.calls, seen.order)
        #expect(order == ["ensure", "call"], "the create went before the user.ensure")
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.path == "v1/ops")
        let body = try JSONDecoder().decode(JSONValue.self, from: call.body)
        #expect(body == .object(["op": .string("cloud.machine.create"), "params": params,
                                 "idempotency_key": .string("key-1"), "origin": .string("user")]))
    }

    @Test func noUsableSessionIsTheRouteUnavailable() async {
        struct NoSession: Error {}
        let ops = CloudPersonCreate.ops({ _, _ in throw NoSession() }, after: {})
        await #expect(throws: CloudPersonCreate.Unavailable.self) { _ = try await ops("cloud.machine.create", .object([:]), "k", .user) }
    }

    @Test func aTransportFailureMayHaveReachedTheServerSoItIsNoFallback() async {
        let ops = CloudPersonCreate.ops({ _, _ in throw URLError(.timedOut) }, after: {})
        await #expect(throws: URLError.self) { _ = try await ops("cloud.machine.create", .object([:]), "k", .user) }
    }

    /// A direct create whose first attempt lost its connection (it may have run) and whose resend is refused by the
    /// route is no ``CloudPersonCreate/Unavailable``: the relay would send a new key and make a second machine. It is
    /// an indeterminate answer, not a definitive refusal, so a Retry sends the same key on the direct route.
    @Test func aRouteRefusalOfAResendAfterAConnectionFailureIsNoFallback() async {
        let refusal = Data(#"{"_tag":"Unauthenticated","code":"auth.unauthenticated","message":"expired"}"#.utf8)
        let ops = CloudPersonCreate.ops({ _, _ in
            // What the session call's hedge notes when it sends the keyed create again after a connection failure.
            CloudPersonCreate.resends?.note()
            return refusal
        }, after: {})
        await #expect(throws: CloudAppOpFailure.self) {
            do { _ = try await ops("cloud.machine.create", .object([:]), "k", .user) } catch let failure as CloudAppOpFailure {
                #expect(failure.code == CloudPersonCreate.indeterminate)
                #expect(!CloudStartCore().isDefinitiveRefusal(failure), "a Retry keeps the key")
                throw failure
            }
        }
        // The same refusal with no resend never reached the op: the relay may take the create with a new key.
        let once = CloudPersonCreate.ops({ _, _ in refusal }, after: {})
        await #expect(throws: CloudPersonCreate.Unavailable.self) { _ = try await once("cloud.machine.create", .object([:]), "k", .user) }
    }

    // MARK: The answer

    @Test func aPlanRefusalIsTheRelaysRefusalNotAFallback() throws {
        let reply = #"{"ok":false,"op":"cloud.machine.create","error":{"code":"cloud.plan.required","message":"Pro","retryable":false,"details":{"plan":"pro"}}}"#
        #expect(throws: CloudAppOpFailure(code: CloudAppOpFailure.planRequired, message: "Pro", details: .object(["plan": .string("pro")]))) {
            try CloudPersonCreate.answer(Data(reply.utf8))
        }
        let size = #"{"ok":false,"op":"cloud.machine.create","error":{"code":"cloud.size.locked","message":"","retryable":false}}"#
        #expect(throws: CloudAppOpFailure(code: "cmux.cloud.size_locked", message: "cloud.size.locked")) { try CloudPersonCreate.answer(Data(size.utf8)) }
    }

    @Test func theSessionsRefusalOrAnUnknownOpIsTheRouteUnavailable() {
        for reply in [#"{"_tag":"Unauthenticated","code":"auth.unauthenticated","message":"expired"}"#,
                      #"{"_tag":"Forbidden","code":"team.not_member","message":"not a member"}"#,
                      #"{"_tag":"BadRequest","code":"validation.invalid","message":"unknown mutation cloud.machine.create"}"#,
                      #"{"_tag":"OwnerUnreachable","code":"owner.unreachable","message":"cloud.machine.create is not available yet","retryable":true}"#] {
            #expect(throws: CloudPersonCreate.Unavailable.self, "\(reply)") { try CloudPersonCreate.answer(Data(reply.utf8)) }
        }
    }

    @Test func anOpsOwnForbiddenOrAnUnreachableOwnerIsARealAnswer() {
        let forbidden = #"{"ok":false,"op":"cloud.machine.create","error":{"code":"auth.forbidden","message":"no","retryable":false}}"#
        #expect(throws: CloudAppOpFailure(code: "cmux.cloud.forbidden", message: "no")) { try CloudPersonCreate.answer(Data(forbidden.utf8)) }
        // The op may have run: the key stays on this route.
        let unreachable = #"{"_tag":"OwnerUnreachable","code":"owner.unreachable","message":"timeout","retryable":true}"#
        #expect(throws: CloudAppOpFailure(code: "cmux.cloud.upstream_error", message: "timeout")) { try CloudPersonCreate.answer(Data(unreachable.utf8)) }
        #expect(throws: CloudAppOpFailure.self) { try CloudPersonCreate.answer(Data("<html>".utf8)) }
    }

    /// The `created machine` line's note: why the create skipped the spare, from the answer's own spare fields (cmux-platform
    /// `withSpareAnswer`), reason codes and counts only: no spare's machine id.
    @Test func theCreatedMachineLineSaysWhyTheCreateSkippedASpare() throws {
        let reply = #"{"ok":true,"op":"cloud.machine.create","value":{"machine":{"id":"vm_new1"},"spare_skips":{"image":1},"spare_fallback":"all_skipped","spare_skipped":[{"id":"vm_spare9","reason":"image"}]}}"#
        let note = CloudStartCore().spareNote(answer: try CloudPersonCreate.answer(Data(reply.utf8)))
        #expect(note == #"spare_fallback=all_skipped spare_skips={"image":1} spare_skipped=1"#)
        #expect(!note.contains("vm_spare9"))
        #expect(CloudStartCore().spareNote(answer: .object(["machine": .object([:])])) == "spare=none")
    }
}

private actor Seen {
    var calls: [(path: String, body: Data)] = []
    var order: [String] = []
    func call(_ path: String, _ body: Data) { calls.append((path, body)); order.append("call") }
    func ensured() { order.append("ensure") }
}
