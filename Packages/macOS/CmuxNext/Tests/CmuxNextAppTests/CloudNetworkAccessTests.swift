import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextCloud
import Foundation
import Testing

/// Internet Access… (`cloud set-network-access`) sets a Cloud machine's outbound level over the
/// server's stored policy (web/services/vms/networkPolicy.ts): full, trusted (every preset the
/// server serves) or none. It changes only the mode and the presets, so the machine's own ranges
/// and domains stay, and an agent may only turn access off.
@MainActor @Suite(.serialized)
struct CloudNetworkAccessTests {
    static let catalog = ["anthropic", "openai", "github", "npm"]
    static let presets = catalog.map { CloudNetworkPolicyState.Preset(id: $0, label: $0) }
    static let range = CloudNetworkPolicy.Range(cidr: "10.0.0.0/8", port: 5432, protocol: "tcp", note: "db")

    static func state(_ policy: CloudNetworkPolicy, applied: String = "applied") -> CloudNetworkPolicyState {
        CloudNetworkPolicyState(policy: policy, presets: presets, applied: .init(state: applied, error: nil))
    }

    // MARK: The answer

    @Test func theServerAnswerDecodesWithItsCatalogAndStatus() throws {
        let data = Data(#"""
        {"presets":[{"id":"github","label":"GitHub","domains":["github.com"]}],"requiredDomains":["files.cmux.com"],
         "policy":{"version":1,"mode":"allowlist","ranges":[{"cidr":"10.0.0.0/8","port":5432,"protocol":"tcp"}],
                   "domains":["example.com"],"presets":["github"],"allowDns":false},
         "applied":{"state":"failed","errorCode":"provider_rejected","error":"The provider refused the rules."}}
        """#.utf8)
        let state = try JSONDecoder().decode(CloudNetworkPolicyState.self, from: data)
        #expect(state.policy.mode == .allowlist)
        #expect(state.policy.ranges == [CloudNetworkPolicy.Range(cidr: "10.0.0.0/8", port: 5432, protocol: "tcp", note: nil)])
        #expect(state.policy.domains == ["example.com"])
        #expect(state.policy.allowDns == false)
        #expect(state.presets.map(\.id) == ["github"])
        #expect(state.applied?.state == "failed")
        #expect(state.applied?.error == "The provider refused the rules.")
        let bare = try JSONDecoder().decode(CloudNetworkPolicy.self, from: Data(#"{"mode":"full"}"#.utf8))
        #expect(bare == CloudNetworkPolicy(mode: .full))
    }

    @Test func thePutBodyKeepsEveryStoredField() throws {
        let policy = CloudNetworkPolicy(mode: .none, ranges: [Self.range], domains: ["example.com"], presets: ["npm"], allowDns: false)
        let data = try JSONSerialization.data(withJSONObject: policy.body)
        #expect(try JSONDecoder().decode(CloudNetworkPolicy.self, from: data) == policy)
    }

    // MARK: The levels

    @Test func eachLevelChangesOnlyTheModeAndTrustedAddsTheServersPresets() {
        let current = CloudNetworkPolicy(mode: .full, ranges: [Self.range], domains: ["example.com"], presets: ["npm"], allowDns: false)
        let trusted = CloudNetworkAccess.trusted.applied(to: current, presets: Self.catalog)
        #expect(trusted.mode == .allowlist)
        #expect(trusted.presets == ["npm", "anthropic", "openai", "github"])
        #expect(trusted.ranges == current.ranges && trusted.domains == current.domains && trusted.allowDns == false)
        let none = CloudNetworkAccess.noInternet.applied(to: trusted, presets: Self.catalog)
        #expect(none.mode == .none)
        #expect(none.presets == trusted.presets, "a mode switch keeps the lists, so switching back restores them")
        #expect(CloudNetworkAccess.full.applied(to: none, presets: Self.catalog).mode == .full)
    }

    /// The server opens all public egress for a portless 0.0.0.0/0 or ::/0 range in any mode, so a
    /// restricted level drops those (a range with a port stays, and full keeps every range).
    @Test func aRestrictedLevelDropsWholeInternetRanges() {
        let whole4 = CloudNetworkPolicy.Range(cidr: "0.0.0.0/0", port: nil, protocol: nil, note: nil)
        let whole6 = CloudNetworkPolicy.Range(cidr: "::/0", port: nil, protocol: nil, note: nil)
        let smtp = CloudNetworkPolicy.Range(cidr: "0.0.0.0/0", port: 25, protocol: "tcp", note: nil)
        let current = CloudNetworkPolicy(mode: .full, ranges: [whole4, Self.range, whole6, smtp])
        for level in [CloudNetworkAccess.noInternet, .trusted] {
            #expect(level.applied(to: current, presets: Self.catalog).ranges == [Self.range, smtp], "\(level)")
        }
        #expect(CloudNetworkAccess.full.applied(to: current, presets: Self.catalog).ranges == current.ranges)
    }

    @Test func aPolicyReadsAsItsLevelOrCustom() {
        #expect(CloudNetworkAccess.level(of: CloudNetworkPolicy(mode: .full), presets: Self.catalog) == .full)
        #expect(CloudNetworkAccess.level(of: CloudNetworkPolicy(mode: .none, presets: ["npm"]), presets: Self.catalog) == .noInternet)
        #expect(CloudNetworkAccess.level(of: CloudNetworkPolicy(mode: .allowlist, presets: Self.catalog), presets: Self.catalog) == .trusted)
        #expect(CloudNetworkAccess.level(of: CloudNetworkPolicy(mode: .allowlist, presets: ["npm"]), presets: Self.catalog) == nil)
        #expect(CloudNetworkAccess.level(of: CloudNetworkPolicy(mode: .allowlist, domains: ["example.com"], presets: Self.catalog),
                                         presets: Self.catalog) == nil)
    }

    @Test func wideningIsAMoreOpenModeOrANewPreset() {
        let full = CloudNetworkPolicy(mode: .full), none = CloudNetworkPolicy(mode: .none)
        let some = CloudNetworkPolicy(mode: .allowlist, presets: ["npm"]), more = CloudNetworkPolicy(mode: .allowlist, presets: ["npm", "github"])
        #expect(CloudNetworkAccess.widens(from: none, to: some))
        #expect(CloudNetworkAccess.widens(from: some, to: full))
        #expect(CloudNetworkAccess.widens(from: some, to: more))
        #expect(!CloudNetworkAccess.widens(from: full, to: some))
        #expect(!CloudNetworkAccess.widens(from: more, to: some))
        #expect(!CloudNetworkAccess.widens(from: some, to: none))
        #expect(!CloudNetworkAccess.widens(from: full, to: full))
    }

    // MARK: The action

    @Test func theSettingIsACLIActionWithExactlyTheThreeLevels() throws {
        let services = MachineIconTests.services()
        let descriptor = try #require(services.registry.descriptor(for: "cloudSetNetworkAccess"))
        #expect(descriptor.cliName == "cloud set-network-access")
        #expect(descriptor.targets == [.machine])
        #expect(descriptor.waitsForResult, "a CLI or MCP call waits for the server's answer, not the 2 s default")
        #expect(descriptor.surfaces.contains(.contextMenu))
        let argument = try #require(descriptor.arguments.first)
        #expect(argument.name == "access")
        guard case .enumeration(let cases) = argument.kind else {
            Issue.record("access is not a choice")
            return
        }
        #expect(cases.map(\.value) == CloudNetworkAccess.allCases.map(\.rawValue))
        #expect(cases.map(\.value) == ["full", "trusted", "none"])
    }

    /// Runs the action as `origin` from `start` and answers its result and what it wrote.
    func run(_ access: String, from start: CloudNetworkPolicy, origin: ActionOrigin, applied: String = "applied",
             scope: ActionRunScope? = nil)
        async throws -> (result: Result<[String: ActionResultValue], ActionWorkFailure>, written: [CloudNetworkPolicy]) {
        let services = MachineIconTests.services()
        let session = MachineIconTests.cloudMachine(services, id: "vm-net-\(UUID().uuidString.prefix(8))")
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .machine, id: session.machineID),
                                          arguments: ["access": .string(access)], origin: origin)
        var written: [CloudNetworkPolicy] = []
        let run = services.registry.capturingRun {
            do {
                try ActionRunScope.$current.withValue(scope) {
                try CloudNetworkAccessActions.set(invocation, AppActionContext(services: services),
                                                  read: { id in
                                                       #expect(id == session.machineID)
                                                       return Self.state(start, applied: applied)
                                                   },
                                                   write: { _, policy in
                                                       written.append(policy)
                                                       return Self.state(policy)
                                                   })
                }
            } catch { Issue.record("refused: \(error)") }
        }
        let task = try #require(run.results.first)
        return (await task.value, written)
    }

    @Test(arguments: [ActionOrigin.cli, .script])
    func aCLIRunWritesTheLevelAndGetsItBack(origin: ActionOrigin) async throws {
        let start = CloudNetworkPolicy(mode: .full, ranges: [Self.range])
        let (result, written) = try await run("trusted", from: start, origin: origin)
        guard case .success(let fields) = result else { Issue.record("set-network-access failed: \(result)"); return }
        #expect(fields["network_access"] == .string("custom"), "the machine's own range keeps it custom")
        #expect(fields["mode"] == .string("allowlist"))
        #expect(fields["applied"] == .string("applied"))
        #expect(written.map(\.mode) == [.allowlist])
        #expect(written.first?.ranges == [Self.range])
        #expect(written.first?.presets == Self.catalog)
    }

    @Test func anUnchangedAppliedLevelIsNotWrittenButAFailedOneIs() async throws {
        let none = CloudNetworkPolicy(mode: .none)
        let same = try await run("none", from: none, origin: .cli)
        #expect(same.written.isEmpty)
        guard case .success(let fields) = same.result else { Issue.record("failed: \(same.result)"); return }
        #expect(fields["network_access"] == .string("none"))
        let retried = try await run("none", from: none, origin: .cli, applied: "failed")
        #expect(retried.written == [none], "a PUT retries a failed apply")
    }

    @Test func anAgentMayOnlyTurnAccessOff() async throws {
        let narrowed = try await run("none", from: CloudNetworkPolicy(mode: .full), origin: .mcp)
        #expect(narrowed.written.map(\.mode) == [.none])
        // Even a narrowing to trusted is refused: judged against a read a newer edit made stale,
        // it could reopen what a person closed (the PUT is unconditional).
        let trusted = try await run("trusted", from: CloudNetworkPolicy(mode: .full), origin: .mcp)
        #expect(trusted.written.isEmpty)
        guard case .failure = trusted.result else { Issue.record("an agent chose trusted"); return }
        let widened = try await run("full", from: CloudNetworkPolicy(mode: .none), origin: .mcp)
        #expect(widened.written.isEmpty)
        guard case .failure(let failure) = widened.result else { Issue.record("an agent widened access"); return }
        #expect(failure.message == CloudStrings.networkAccessAgentWidens)
        let nested = try await run("full", from: CloudNetworkPolicy(mode: .none), origin: .user,
                                   scope: ActionRunScope(origin: .mcp, allowsViewChange: false))
        #expect(nested.written.isEmpty, "an action an MCP run nests is still the agent's")
        let person = try await run("full", from: CloudNetworkPolicy(mode: .none), origin: .cli)
        #expect(person.written.map(\.mode) == [.full])
    }

    /// Two runs on one machine never overlap: the second reads only after the first wrote, so an
    /// agent cannot widen from a policy another run already narrowed.
    @Test func runsOnOneMachineReadAfterTheEarlierWrite() async throws {
        @MainActor final class Log { var events: [String] = [] }
        let gate = AsyncStream<Void>.makeStream()
        let log = Log()
        let queue = CloudNetworkAccessQueue()
        // task-owner: this test awaits both runs below.
        let first = Task { @MainActor in
            try await queue.serialized("vm-serial") {
                log.events.append("first read")
                var waiting = gate.stream.makeAsyncIterator()
                _ = await waiting.next()
                log.events.append("first write")
                return 1
            }
        }
        for _ in 0..<100 where log.events.isEmpty { await Task.yield() }
        try #require(log.events == ["first read"])
        // task-owner: this test awaits it below.
        let second = Task { @MainActor in
            try await queue.serialized("vm-serial") {
                log.events.append("second read")
                return 2
            }
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(log.events == ["first read"], "the second run waits for the first")
        gate.continuation.yield(())
        #expect(try await first.value == 1)
        #expect(try await second.value == 2)
        #expect(log.events == ["first read", "first write", "second read"])
        #expect(!queue.isBusy("vm-serial"), "the tail ends with its run")
    }

    /// A run on another machine does not wait for a run that is still open on the first one.
    @Test func runsOnDifferentMachinesDoNotWaitForEachOther() async throws {
        @MainActor final class Log { var events: [String] = [] }
        let gate = AsyncStream<Void>.makeStream()
        let log = Log()
        let queue = CloudNetworkAccessQueue()
        // task-owner: this test awaits it below.
        let first = Task { @MainActor in
            try await queue.serialized("vm-a") {
                log.events.append("a read")
                var waiting = gate.stream.makeAsyncIterator()
                _ = await waiting.next()
                log.events.append("a write")
                return 1
            }
        }
        for _ in 0..<100 where log.events.isEmpty { await Task.yield() }
        try #require(log.events == ["a read"])
        let other = try await queue.serialized("vm-b") {
            log.events.append("b read")
            return 2
        }
        #expect(other == 2)
        #expect(log.events == ["a read", "b read"], "vm-b ran while vm-a's run was still open")
        #expect(!queue.isBusy("vm-b"))
        #expect(queue.isBusy("vm-a"))
        gate.continuation.yield(())
        #expect(try await first.value == 1)
        #expect(log.events == ["a read", "b read", "a write"])
        #expect(!queue.isBusy("vm-a"))
    }

    /// A run that throws still ends its tail: the next run on that machine starts.
    @Test func aFailedRunDoesNotHoldTheNextOne() async throws {
        struct Refused: Error {}
        let queue = CloudNetworkAccessQueue()
        await #expect(throws: Refused.self) {
            try await queue.serialized("vm-fail") { () async throws -> Int in throw Refused() }
        }
        #expect(!queue.isBusy("vm-fail"))
        #expect(try await queue.serialized("vm-fail") { 3 } == 3)
    }

    @Test(arguments: ["", "open", "allowlist", "FULLY"])
    func aLevelThatIsNotAChoiceIsRefused(text: String) {
        let services = MachineIconTests.services()
        let session = MachineIconTests.cloudMachine(services, id: "vm-net-bad")
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .machine, id: session.machineID),
                                          arguments: ["access": .string(text)], origin: .cli)
        var reads = 0
        #expect(throws: ActionFailure.self) {
            try CloudNetworkAccessActions.set(invocation, AppActionContext(services: services),
                                               read: { _ in reads += 1; return Self.state(CloudNetworkPolicy(mode: .full)) },
                                               write: { _, policy in Self.state(policy) })
        }
        #expect(reads == 0)
    }
}
