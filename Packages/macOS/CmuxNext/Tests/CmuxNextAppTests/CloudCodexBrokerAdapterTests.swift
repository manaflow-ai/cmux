import Foundation
import Testing
@testable import CmuxNextCloud

@Suite("Cloud Codex broker app adapter", .serialized, .timeLimit(.minutes(1)))
struct CloudCodexBrokerAdapterTests {
    actor Files {
        var values: [String: [String: Data]] = [:]
        var live = true
        var removals = 0
        var cancelledRemoval = false
        var rejectsCapability = false
        func rejectCapability() { rejectsCapability = true }
        var removalObserver: (Int, CheckedContinuation<Void, Never>)?
        func waitForRemovals(_ count: Int) async {
            if removals >= count { return }
            await withCheckedContinuation { removalObserver = (count, $0) }
        }
        var removalGate: CloudCodexBrokerTests.Gate?
        func blockNextRemoval(_ gate: CloudCodexBrokerTests.Gate) { removalGate = gate }
        var pausedChecks = 0
        var pausedWaiter: CheckedContinuation<Void, Never>?
        func pause() { live = false }
        func resume() { live = true }
        func waitForTwoPausedChecks() async {
            if pausedChecks >= 2 { return }
            await withCheckedContinuation { pausedWaiter = $0 }
        }
        /// Answers the next liveness checks in order before falling back to `live`.
        var scriptedLive: [Bool] = []
        func scriptLive(_ answers: [Bool]) { scriptedLive = answers }
        func isLive() -> Bool {
            if !scriptedLive.isEmpty { return scriptedLive.removeFirst() }
            if !live {
                pausedChecks += 1
                if pausedChecks >= 2 { pausedWaiter?.resume(); pausedWaiter = nil }
            }
            return live
        }
        func read(_ machine: String, _ path: String) -> Data? { values[machine]?[path] }
        func write(_ machine: String, _ path: String, _ data: Data) { values[machine, default: [:]][path] = data }
        func remove(_ machine: String, _ path: String) async {
            if let gate = removalGate { removalGate = nil; await gate.pause() }
            cancelledRemoval = cancelledRemoval || Task.isCancelled
            removals += 1; values[machine]?[path] = nil
            if let (count, observer) = removalObserver, removals >= count {
                removalObserver = nil; observer.resume()
            }
        }
        func commit(_ machine: String, _ a: String, _ b: String, _ c: String, _ d: String) {
            values[machine, default: [:]][b] = values[machine]?[a]
            values[machine, default: [:]][d] = values[machine]?[c]
            commits[machine, default: 0] += 1
            if let (target, count, observer) = commitObserver, target == machine, commits[machine, default: 0] >= count {
                commitObserver = nil; observer.resume()
            }
        }
        var commits: [String: Int] = [:]
        var commitObserver: (String, Int, CheckedContinuation<Void, Never>)?
        func waitForCommits(_ machine: String, _ count: Int) async {
            if commits[machine, default: 0] >= count { return }
            await withCheckedContinuation { commitObserver = (machine, count, $0) }
        }
        nonisolated func target(_ machine: String) -> CloudCodexBrokerTarget {
            CloudCodexBrokerTarget(machineID: machine, capability: {
                if await self.rejectsCapability { throw CloudCodexBrokerError.unsupportedMachine }
                return .init(ownerVM: true, protocolVersion: 1, codexExternalAccessToken: true)
            }, makeDirectory: { _ in }, readFile: { await self.read(machine, $0) },
            writeFile: { path, data, _ in try Task.checkCancellation(); await self.write(machine, path, data) },
            commitFiles: { a, b, c, d in await self.commit(machine, a, b, c, d) },
            removeFile: { try Task.checkCancellation(); await self.remove(machine, $0) },
            isLive: { try Task.checkCancellation(); return await self.isLive() })
        }
    }

    private func fixture(shortGrants: Bool = false) throws -> (URL, CloudCodexBrokerAdapter.Launch) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fake = root.appendingPathComponent("broker.sh")
        let script = #"""
#!/bin/sh
holder="$3"
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
  if printf '%s' "$line" | grep -q '"method":"login"'; then
    touch "$holder/signed-in"
    echo "{\"id\":$id,\"result\":{\"verificationUrl\":\"https://auth.openai.com/codex/device\",\"userCode\":\"TEST-CODE\"}}"
  elif [ -f "$holder/signed-in" ]; then
    expiry=2147483647; if [ "SHORT_GRANTS" = yes ]; then expiry=$(($(date +%s) + 123)); fi
    echo "{\"id\":$id,\"result\":{\"accessToken\":\"short-access\",\"chatgptAccountId\":\"account\",\"expiresAt\":$expiry}}"
  else
    echo "{\"id\":$id,\"error\":\"codex_auth_unavailable\"}"
  fi
done
"""#.replacingOccurrences(of: "SHORT_GRANTS", with: shortGrants ? "yes" : "no")
        try script.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        return (root, .init(executable: fake, prefix: [], codex: URL(fileURLWithPath: "/bin/false")))
    }

    @Test func homesAreStableAndSeparateForEveryAccountScope() throws {
        let (root, launch) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = Files()
        let adapter = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { nil }, launch: { launch }, target: { _, id in files.target(id) })
        let scopes = [CloudCodexBrokerScope(userID: "user", teamID: nil),
                      .init(userID: "user", teamID: ""), .init(userID: "user", teamID: "a/b"),
                      .init(userID: "user/a", teamID: "b"), .init(userID: "other", teamID: nil)]
        #expect(Set(scopes.map { adapter.home(for: $0) }).count == scopes.count)
        #expect(adapter.home(for: scopes[0]) == adapter.home(for: scopes[0]))
        #expect(adapter.home(for: scopes[0]).lastPathComponent.count == 64)
    }

    @Test func cancelledFirstLoginPreservesVMModeAndStopsRegistration() async throws {
        let (root, launch) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = Files()
        let scope = CloudCodexBrokerScope(userID: "user", teamID: nil)
        let registry = CloudCodexBrokerRegistry()
        let adapter = CloudCodexBrokerAdapter(root: root, registry: registry, currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        await files.write("vm", CloudCodexBroker.modePath, Data("team\n".utf8))
        await #expect(throws: CloudCodexBrokerError.cancelled) {
            try await adapter.run(machineID: "vm", scope: scope, confirmed: true) { _ in false }
        }
        #expect(await files.read("vm", CloudCodexBroker.modePath) == Data("team\n".utf8))
        #expect(await files.read("vm", CloudCodexBroker.accessPath) == nil)
        let broker = try #require(await registry.existing(for: scope))
        #expect(await broker.registeredMachineIDs().isEmpty)
        await adapter.shutdown()
    }

    /// Leo, 2026-11-05: "those subscriptions should all be detectable". Once the person says yes, a
    /// machine gets the access the Mac's own Codex holds: no device code, and the private holder never
    /// signs in, so nothing but the Mac's Codex ever refreshes the Mac's sign-in.
    @Test func theMacsOwnCodexSignInReplacesTheDeviceCodeOnceAllowed() async throws {
        let (root, launch) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = Files()
        let scope = CloudCodexBrokerScope(userID: "user", teamID: nil)
        let adapter = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        let allowed = Flag()
        adapter.localSignIn = {
            guard await allowed.value else { return nil }
            return CloudCodexAccessGrant(accessToken: "mac-access", chatgptAccountID: "account", expiresAt: Date().addingTimeInterval(3600))
        }
        var asked = 0, prompts = 0
        try await adapter.run(machineID: "vm", scope: scope, confirmed: true,
                              askLocalSignIn: { asked += 1; await allowed.set(); return true },
                              presentDeviceCode: { _ in prompts += 1; return false })
        #expect(asked == 1 && prompts == 0)
        let delivered = try #require(await files.read("vm", CloudCodexBroker.accessPath))
        #expect(String(decoding: delivered, as: UTF8.self).contains("mac-access"))
        #expect(!String(decoding: delivered, as: UTF8.self).contains("refresh"))
        // Silent after the yes: a second machine is asked nothing.
        try await adapter.run(machineID: "vm2", scope: scope, confirmed: true,
                              askLocalSignIn: { asked += 1; return true }, presentDeviceCode: { _ in prompts += 1; return false })
        #expect(asked == 1 && prompts == 0)
        await adapter.shutdown()
    }

    /// A grant from the Mac's Codex renews while a newer Mac token still qualifies (15 min left), not
    /// 2 minutes before its end, when nothing from the Mac would be accepted any more.
    @Test func aMacGrantRenewsBeforeTheLocalCutoff() async throws {
        let (root, launch) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = Files()
        let scope = CloudCodexBrokerScope(userID: "user", teamID: nil)
        let registry = CloudCodexBrokerRegistry()
        let adapter = CloudCodexBrokerAdapter(root: root, registry: registry, currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        let expiry = Date().addingTimeInterval(3600)
        adapter.localSignIn = { CloudCodexAccessGrant(accessToken: "mac-access", chatgptAccountID: "account", expiresAt: expiry) }
        try await adapter.run(machineID: "vm", scope: scope, confirmed: true, askLocalSignIn: { true }, presentDeviceCode: { _ in false })
        let broker = try #require(await registry.existing(for: scope))
        let renewal = try #require(await broker.scheduledRenewal)
        #expect(renewal <= expiry.addingTimeInterval(-CloudCodexLocalAccess.minimumLifetime))
        await adapter.shutdown()
    }

    /// Taking the yes back stops the Mac's token at once: a later machine never gets the cached one.
    @Test func aTakenBackYesNeverDeliversTheCachedMacToken() async throws {
        let (root, launch) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = Files()
        let scope = CloudCodexBrokerScope(userID: "user", teamID: nil)
        let adapter = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        let allowed = Flag()
        await allowed.set()
        adapter.localSignIn = {
            guard await allowed.value else { return nil }
            return CloudCodexAccessGrant(accessToken: "mac-access", chatgptAccountID: "account", expiresAt: Date().addingTimeInterval(3600))
        }
        try await adapter.run(machineID: "vm", scope: scope, confirmed: true, askLocalSignIn: { true }, presentDeviceCode: { _ in false })
        await allowed.clear()
        var prompts = 0
        try await adapter.run(machineID: "vm2", scope: scope, confirmed: true,
                              askLocalSignIn: { false }, presentDeviceCode: { _ in prompts += 1; return true })
        #expect(prompts == 1)
        let delivered = try #require(await files.read("vm2", CloudCodexBroker.accessPath))
        #expect(!String(decoding: delivered, as: UTF8.self).contains("mac-access"))
        await adapter.shutdown()
    }

    /// The Mac signed in to another Codex account: the cached token of the first is never delivered again.
    @Test func anotherMacAccountDropsTheCachedToken() async throws {
        let (root, launch) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = Files()
        let scope = CloudCodexBrokerScope(userID: "user", teamID: nil)
        let adapter = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        let switched = Flag(), expiry = Date().addingTimeInterval(3600)
        adapter.localSignIn = {
            await switched.value ? CloudCodexAccessGrant(accessToken: "mac-b", chatgptAccountID: "b", expiresAt: expiry)
                                 : CloudCodexAccessGrant(accessToken: "mac-a", chatgptAccountID: "a", expiresAt: expiry)
        }
        try await adapter.run(machineID: "vm", scope: scope, confirmed: true, askLocalSignIn: { true }, presentDeviceCode: { _ in false })
        await switched.set()
        try await adapter.run(machineID: "vm2", scope: scope, confirmed: true, askLocalSignIn: { true }, presentDeviceCode: { _ in false })
        let delivered = String(decoding: try #require(await files.read("vm2", CloudCodexBroker.accessPath)), as: UTF8.self)
        #expect(delivered.contains("mac-b") && !delivered.contains("mac-a"))
        await adapter.shutdown()
    }

    /// A no (or no Mac sign-in) keeps the device code exactly as before.
    @Test func aDeclinedMacSignInFallsBackToTheDeviceCode() async throws {
        let (root, launch) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = Files()
        let scope = CloudCodexBrokerScope(userID: "user", teamID: nil)
        let adapter = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        adapter.localSignIn = { nil }
        var prompts = 0
        try await adapter.run(machineID: "vm", scope: scope, confirmed: true,
                              askLocalSignIn: { false }, presentDeviceCode: { _ in prompts += 1; return true })
        #expect(prompts == 1)
        let delivered = try #require(await files.read("vm", CloudCodexBroker.accessPath))
        #expect(String(decoding: delivered, as: UTF8.self).contains("short-access"))
        await adapter.shutdown()
    }

    actor Flag {
        var value = false
        func set() { value = true }
        func clear() { value = false }
    }

    @Test func reusesLoginAcrossVMsAndAppRestartAndCleansDeliveredFiles() async throws {
        let (root, launch) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = Files()
        let scope = CloudCodexBrokerScope(userID: "user", teamID: "team")
        var prompts = 0
        let adapter = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        let present: @MainActor @Sendable (CloudCodexLoginPrompt) async -> Bool = { prompt in
            #expect(prompt.userCode == "TEST-CODE"); prompts += 1; return true
        }
        try await adapter.run(machineID: "one", scope: scope, confirmed: true, presentDeviceCode: present)
        try await adapter.run(machineID: "two", scope: scope, confirmed: true, presentDeviceCode: present)
        #expect(prompts == 1)
        #expect(await files.read("one", CloudCodexBroker.accessPath) != nil)
        #expect(await files.read("two", CloudCodexBroker.accessPath) != nil)
        await adapter.shutdown()
        #expect(await files.read("one", CloudCodexBroker.accessPath) == nil)
        #expect(await files.read("two", CloudCodexBroker.accessPath) == nil)
        let restarted = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        try await restarted.run(machineID: "three", scope: scope, confirmed: true, presentDeviceCode: present)
        #expect(prompts == 1)
        await restarted.shutdown()
    }

    /// #33482: a quit or an update leaves delivered access on each machine, so an unattended
    /// Cloud Codex run keeps working; the next run's sign-out still erases it whole.
    @Test func quitLeavesDeliveredAccessAndTheNextRunsSignOutErasesIt() async throws {
        let (root, launch) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = Files()
        let scope = CloudCodexBrokerScope(userID: "user", teamID: nil)
        let adapter = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        await files.write("one", CloudCodexBroker.modePath, Data("team\n".utf8))
        try await adapter.run(machineID: "one", scope: scope, confirmed: true) { _ in true }
        try await adapter.run(machineID: "two", scope: scope, confirmed: true) { _ in true }
        let delivered = try #require(await files.read("one", CloudCodexBroker.accessPath))
        let removalsBefore = await files.removals
        await adapter.detachForQuit()
        #expect(await files.removals == removalsBefore)
        #expect(await files.read("one", CloudCodexBroker.accessPath) == delivered)
        #expect(await files.read("two", CloudCodexBroker.accessPath) != nil)
        #expect(await files.read("one", CloudCodexBroker.modePath) == Data("own\n".utf8))
        #expect(adapter.pendingCleanup.isEmpty)
        await #expect(throws: CloudCodexBrokerError.cancelled) {
            try await adapter.run(machineID: "one", scope: scope, confirmed: true) { _ in true }
        }
        // The relaunched app delivers again over the marker its last run left, then signs out:
        // each machine gets back the mode it had before the first run, not that run's marker.
        let relaunched = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        try await relaunched.run(machineID: "one", scope: scope, confirmed: true) { _ in true }
        try await relaunched.run(machineID: "two", scope: scope, confirmed: true) { _ in true }
        await relaunched.signOut()
        #expect(await files.read("one", CloudCodexBroker.accessPath) == nil)
        #expect(await files.read("one", CloudCodexBroker.modePath) == Data("team\n".utf8))
        #expect(await files.read("two", CloudCodexBroker.accessPath) == nil)
        #expect(await files.read("two", CloudCodexBroker.modePath) == nil)
        await relaunched.shutdown()
    }

    /// An `own` mode the person chose (`cr use`, an agent login) before any broker delivery is
    /// theirs: a revoke restores it rather than taking it for an earlier run's marker.
    /// cmux#33878: renewal picks back up after a relaunch on each machine the last run left access on,
    /// so a Cloud Codex run outlives the access that was on the machine when cmux quit.
    @Test func relaunchResumesRenewalOnMachinesTheLastRunLeftAccessOn() async throws {
        let (root, launch) = try fixture(shortGrants: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = Files()
        let scope = CloudCodexBrokerScope(userID: "user", teamID: nil)
        let adapter = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        await files.write("one", CloudCodexBroker.modePath, Data("team\n".utf8))
        try await adapter.run(machineID: "one", scope: scope, confirmed: true) { _ in true }
        await adapter.detachForQuit()
        let left = try #require(await files.read("one", CloudCodexBroker.accessPath))
        let commitsAtQuit = await files.commits["one", default: 0]

        let relaunched = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        #expect(await !relaunched.delivers(machineID: "one", scope: scope))
        await relaunched.resume(scope: scope, liveMachineIDs: ["one"])
        #expect(await relaunched.delivers(machineID: "one", scope: scope))
        // The left grant expires 123 s out, so its renewal is due within seconds.
        await files.waitForCommits("one", commitsAtQuit + 1)
        let renewed = try #require(await files.read("one", CloudCodexBroker.accessPath))
        #expect(renewed != left)
        #expect(await files.read("one", CloudCodexBroker.modePath) == Data("own\n".utf8))
        // A renewal keeps the person's mode from before the first run, so a sign-out still restores it.
        await relaunched.signOut()
        #expect(await files.read("one", CloudCodexBroker.accessPath) == nil)
        #expect(await files.read("one", CloudCodexBroker.modePath) == Data("team\n".utf8))
        #expect(CloudCodexDeliveryRecord(home: relaunched.home(for: scope)).entries().isEmpty)
    }

    /// cmux#33877: after a relaunch, a sign-out erases the access an earlier run left, without a new
    /// Codex run first. A machine paused at the sign-out is erased, never renewed, once it is back.
    @Test func signOutAfterRelaunchErasesAccessAnEarlierRunLeft() async throws {
        let (root, launch) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = Files()
        let scope = CloudCodexBrokerScope(userID: "user", teamID: nil)
        let adapter = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        await files.write("one", CloudCodexBroker.modePath, Data("team\n".utf8))
        try await adapter.run(machineID: "one", scope: scope, confirmed: true) { _ in true }
        try await adapter.run(machineID: "two", scope: scope, confirmed: true) { _ in true }
        await adapter.detachForQuit()
        #expect(CloudCodexDeliveryRecord(home: adapter.home(for: scope)).entries() == ["one": false, "two": false])

        // "two" is paused when the relaunched app lists its machines and when it signs out.
        let relaunched = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        await relaunched.resume(scope: scope, liveMachineIDs: ["one"])
        await relaunched.signOut()
        #expect(await files.read("one", CloudCodexBroker.accessPath) == nil)
        #expect(await files.read("one", CloudCodexBroker.modePath) == Data("team\n".utf8))
        #expect(await files.read("two", CloudCodexBroker.accessPath) != nil)
        #expect(CloudCodexDeliveryRecord(home: relaunched.home(for: scope)).entries() == ["two": true])

        // Signed back in, with "two" running again: it is erased, not renewed.
        let later = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        await later.resume(scope: scope, liveMachineIDs: ["one", "two"])
        #expect(await files.read("two", CloudCodexBroker.accessPath) == nil)
        #expect(await files.read("two", CloudCodexBroker.modePath) == nil)
        #expect(await !later.delivers(machineID: "two", scope: scope))
        #expect(CloudCodexDeliveryRecord(home: later.home(for: scope)).entries().isEmpty)
        await later.shutdown()
    }

    /// cmux#33877: the Cloud off switch and an account or team switch erase what an earlier run left
    /// too; a machine whose Codex the person signed in some other way since is left alone.
    @Test func offSwitchAndSwitchAfterRelaunchEraseAccessAnEarlierRunLeft() async throws {
        let (root, launch) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = Files()
        let personal = CloudCodexBrokerScope(userID: "user", teamID: nil)
        let adapter = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { personal }, launch: { launch }, target: { _, id in files.target(id) })
        for machine in ["one", "two", "mine"] {
            try await adapter.run(machineID: machine, scope: personal, confirmed: true) { _ in true }
        }
        await adapter.detachForQuit()
        // While cmux was quit the person signed Codex in on "mine" themselves.
        await files.write("mine", CloudCodexBroker.modePath, Data("personal\n".utf8))

        let off = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { personal }, launch: { launch }, target: { _, id in files.target(id) })
        await off.resume(scope: personal, liveMachineIDs: ["one", "mine"])
        #expect(await files.read("mine", CloudCodexBroker.accessPath) != nil)
        #expect(await files.read("mine", CloudCodexBroker.modePath) == Data("personal\n".utf8))
        off.setAvailable(false)
        await off.shutdown()
        #expect(await files.read("one", CloudCodexBroker.accessPath) == nil)
        #expect(await files.read("one", CloudCodexBroker.modePath) == nil)

        #expect(CloudCodexDeliveryRecord(home: off.home(for: personal)).entries() == ["two": true])

        // Cloud back on: one more run delivers to "three" and quits, and the next run switches teams.
        let again = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { personal }, launch: { launch }, target: { _, id in files.target(id) })
        try await again.run(machineID: "three", scope: personal, confirmed: true) { _ in true }
        await again.detachForQuit()
        var current: CloudCodexBrokerScope? = personal
        let switching = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { current }, launch: { launch }, target: { _, id in files.target(id) })
        await switching.resume(scope: personal, liveMachineIDs: ["three"])
        #expect(await files.read("three", CloudCodexBroker.accessPath) != nil)
        current = .init(userID: "user", teamID: "team")
        await switching.scopeDidChange()
        #expect(await files.read("three", CloudCodexBroker.accessPath) == nil)
        #expect(await files.read("three", CloudCodexBroker.modePath) == nil)
        #expect(CloudCodexDeliveryRecord(home: switching.home(for: personal)).entries() == ["two": true])
        await switching.shutdown()
    }

    /// Review of cmux#33877: a relaunch takes back only this holder's delivery. Another Mac's (or
    /// account's) delivery over it is not renewed or erased by this one.
    @Test func resumeLeavesAnotherHoldersDeliveryAlone() async throws {
        let (root, launch) = try fixture()
        let (otherRoot, otherLaunch) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: otherRoot) }
        let files = Files()
        let scope = CloudCodexBrokerScope(userID: "user", teamID: nil)
        let first = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        try await first.run(machineID: "vm", scope: scope, confirmed: true) { _ in true }
        await first.detachForQuit()
        let otherMac = CloudCodexBrokerAdapter(root: otherRoot, registry: .init(), currentScope: { scope }, launch: { otherLaunch }, target: { _, id in files.target(id) })
        try await otherMac.run(machineID: "vm", scope: scope, confirmed: true) { _ in true }
        let theirs = try #require(await files.read("vm", CloudCodexBroker.accessPath))

        let relaunched = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        await relaunched.resume(scope: scope, liveMachineIDs: ["vm"])
        #expect(await !relaunched.delivers(machineID: "vm", scope: scope))
        #expect(CloudCodexDeliveryRecord(home: relaunched.home(for: scope)).entries().isEmpty)
        await relaunched.signOut()
        #expect(await files.read("vm", CloudCodexBroker.accessPath) == theirs)
        await otherMac.shutdown()
    }

    /// Review of cmux#33877: a sign-out before any machine list still marks what the record holds for
    /// erasure, and an erase that fails (the machine paused mid-way) finishes on a later pass.
    @Test func signOutBeforeAnyListAndAFailedEraseStillErase() async throws {
        let (root, launch) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = Files()
        let scope = CloudCodexBrokerScope(userID: "user", teamID: nil)
        let adapter = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        try await adapter.run(machineID: "vm", scope: scope, confirmed: true) { _ in true }
        await adapter.detachForQuit()

        let relaunched = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        await relaunched.signOut()
        #expect(CloudCodexDeliveryRecord(home: relaunched.home(for: scope)).entries() == ["vm": true])

        let later = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        // Live when the pass starts, paused by the time the erase reaches it.
        await files.scriptLive([true, false])
        let left = await later.resume(scope: scope, liveMachineIDs: ["vm"])
        #expect(left == ["vm"])
        #expect(await files.read("vm", CloudCodexBroker.accessPath) != nil)
        #expect(await later.resume(scope: scope, liveMachineIDs: ["vm"]).isEmpty)
        #expect(await files.read("vm", CloudCodexBroker.accessPath) == nil)
        #expect(await files.read("vm", CloudCodexBroker.modePath) == nil)
        #expect(CloudCodexDeliveryRecord(home: later.home(for: scope)).entries().isEmpty)
        await later.shutdown()
    }

    @Test func revokeRestoresAnOwnModeThePersonChose() async throws {
        let (root, launch) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = Files()
        let scope = CloudCodexBrokerScope(userID: "user", teamID: nil)
        let adapter = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        await files.write("vm", CloudCodexBroker.modePath, Data("own\n".utf8))
        try await adapter.run(machineID: "vm", scope: scope, confirmed: true) { _ in true }
        #expect(await files.read("vm", CloudCodexBroker.accessPath) != nil)
        await adapter.signOut()
        #expect(await files.read("vm", CloudCodexBroker.accessPath) == nil)
        #expect(await files.read("vm", CloudCodexBroker.modePath) == Data("own\n".utf8))
        await adapter.shutdown()
    }

    @Test func coalescesConcurrentFirstLoginAndDeviceCodePresentation() async throws {
        let (root, launch) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = Files()
        let scope = CloudCodexBrokerScope(userID: "user", teamID: nil)
        let adapter = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        let gate = CloudCodexBrokerTests.Gate()
        var prompts = 0
        let present: @MainActor @Sendable (CloudCodexLoginPrompt) async -> Bool = { _ in
            prompts += 1
            await gate.pause()
            return true
        }
        let first = Task { try await adapter.run(machineID: "one", scope: scope, confirmed: true, presentDeviceCode: present) }
        let second = Task { try await adapter.run(machineID: "two", scope: scope, confirmed: true, presentDeviceCode: present) }
        await gate.entered()
        #expect(prompts == 1)
        await gate.open()
        try await first.value
        try await second.value
        await adapter.shutdown()
    }

    @Test func taskCancellationRevokesPreviouslyDeliveredAccessWithUncancelledTransport() async throws {
        let (root, launch) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = Files()
        let scope = CloudCodexBrokerScope(userID: "user", teamID: nil)
        let gate = CloudCodexBrokerTests.Gate()
        let adapter = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        try await adapter.run(machineID: "vm", scope: scope, confirmed: true) { _ in true }
        #expect(await files.read("vm", CloudCodexBroker.accessPath) != nil)
        // Make the fake provider request login again while a previous grant remains delivered.
        try FileManager.default.removeItem(at: adapter.home(for: scope).appendingPathComponent("signed-in"))
        let pending = Task {
            try await adapter.run(machineID: "vm", scope: scope, confirmed: true, forceRefresh: true) { _ in
                await gate.pause(); return true
            }
        }
        await gate.entered()
        pending.cancel()
        await gate.open()
        await #expect(throws: (any Error).self) { try await pending.value }
        #expect(await files.read("vm", CloudCodexBroker.accessPath) == nil)
        #expect(adapter.pendingCleanup.isEmpty)
        await adapter.shutdown()
    }

    @Test func pausedRenewalDoesNotIssueCleanupFileRequests() async throws {
        let (root, launch) = try fixture(shortGrants: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = Files()
        let scope = CloudCodexBrokerScope(userID: "user", teamID: nil)
        let adapter = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        try await adapter.run(machineID: "vm", scope: scope, confirmed: true) { _ in true }
        let before = await files.removals
        await files.pause()
        // A second scheduled probe proves the preceding renewal completed.
        await files.waitForTwoPausedChecks()
        #expect(await files.removals == before)
        await adapter.shutdown()
        #expect(adapter.pendingCleanup.contains("vm"))
    }

    @Test func deletingMachineCancelsItsPendingLoginPrompt() async throws {
        let (root, launch) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = Files()
        let scope = CloudCodexBrokerScope(userID: "user", teamID: nil)
        let gate = CloudCodexBrokerTests.Gate()
        let adapter = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        let pending = Task { try await adapter.run(machineID: "vm", scope: scope, confirmed: true) { _ in await gate.pause(); return true } }
        await gate.entered()
        try await adapter.revoke(machineID: "vm", scope: scope)
        await gate.open()
        await #expect(throws: (any Error).self) { try await pending.value }
        #expect(await files.read("vm", CloudCodexBroker.accessPath) == nil)
        await adapter.shutdown()
    }

    @Test func allConcurrentTransfersWaitForPolicyTeardown() async throws {
        let (root, launch) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = Files()
        let scope = CloudCodexBrokerScope(userID: "user", teamID: nil)
        let gate = CloudCodexBrokerTests.Gate()
        let adapter = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        try await adapter.run(machineID: "vm", scope: scope, confirmed: true) { _ in true }
        await files.blockNextRemoval(gate)
        adapter.setAvailable(false)
        await gate.entered()
        adapter.setAvailable(true)
        var finished = 0
        let first = Task { try await adapter.run(machineID: "vm", scope: scope, confirmed: true) { _ in true }; finished += 1 }
        let second = Task { try await adapter.run(machineID: "vm", scope: scope, confirmed: true) { _ in true }; finished += 1 }
        // Give both local holders time to answer; neither transfer may pass
        // the old holder's deliberately blocked cleanup barrier.
        try await Task.sleep(for: .milliseconds(250))
        #expect(finished == 0)
        await gate.open()
        try await first.value
        try await second.value
        #expect(await files.read("vm", CloudCodexBroker.accessPath) != nil)
        await adapter.shutdown()
    }

    @Test func failedShutdownRetainsPreviousModeUntilCleanupSucceeds() async throws {
        let (root, launch) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = Files()
        let scope = CloudCodexBrokerScope(userID: "user", teamID: nil)
        let registry = CloudCodexBrokerRegistry()
        let adapter = CloudCodexBrokerAdapter(root: root, registry: registry, currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        await files.write("vm", CloudCodexBroker.modePath, Data("team\n".utf8))
        try await adapter.run(machineID: "vm", scope: scope, confirmed: true) { _ in true }
        await files.pause()
        await adapter.shutdown()
        #expect(adapter.pendingCleanup.contains("vm"))
        let replacement = CloudCodexBrokerAdapter(root: root, registry: registry, currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        await #expect(throws: CloudCodexBrokerError.remoteDeliveryFailed) {
            try await replacement.run(machineID: "vm", scope: scope, confirmed: true) { _ in true }
        }
        await files.resume()
        try await replacement.run(machineID: "vm", scope: scope, confirmed: true) { _ in true }
        await replacement.shutdown()
        #expect(await files.read("vm", CloudCodexBroker.modePath) == Data("team\n".utf8))
        #expect(await files.read("vm", CloudCodexBroker.accessPath) == nil)
        #expect(replacement.pendingCleanup.isEmpty)
    }

    @Test func confirmedDeletionReleasesFailedCleanupForFutureVMs() async throws {
        let (root, launch) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = Files()
        let scope = CloudCodexBrokerScope(userID: "user", teamID: nil)
        let adapter = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        try await adapter.run(machineID: "deleted", scope: scope, confirmed: true) { _ in true }
        await files.pause()
        adapter.setAvailable(false)
        await adapter.scopeDidChange()
        adapter.setAvailable(true)
        await #expect(throws: CloudCodexBrokerError.remoteDeliveryFailed) {
            try await adapter.run(machineID: "new", scope: scope, confirmed: true) { _ in true }
        }
        await adapter.machineWasDeleted("deleted", scope: scope)
        #expect(!adapter.pendingCleanup.contains("deleted"))
        await files.resume()
        try await adapter.run(machineID: "new", scope: scope, confirmed: true) { _ in true }
        #expect(await files.read("new", CloudCodexBroker.accessPath) != nil)
        await adapter.shutdown()
    }

    @Test func successfulRetirementRetryClearsItsCleanupWarning() async throws {
        let (root, launch) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = Files()
        let scope = CloudCodexBrokerScope(userID: "user", teamID: nil)
        let adapter = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        try await adapter.run(machineID: "vm", scope: scope, confirmed: true) { _ in true }
        await files.pause()
        adapter.setAvailable(false)
        adapter.setAvailable(true)
        await #expect(throws: CloudCodexBrokerError.remoteDeliveryFailed) {
            try await adapter.run(machineID: "new", scope: scope, confirmed: true) { _ in true }
        }
        #expect(adapter.pendingCleanup.contains("vm"))
        await files.resume()
        try await adapter.run(machineID: "new", scope: scope, confirmed: true) { _ in true }
        #expect(adapter.pendingCleanup.isEmpty)
        await adapter.shutdown()
    }

    @Test func quitCleanupIsParallelAndBoundedWhenTransportDoesNotAnswer() async throws {
        let (root, launch) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = Files()
        let scope = CloudCodexBrokerScope(userID: "user", teamID: nil)
        let adapter = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        try await adapter.run(machineID: "one", scope: scope, confirmed: true) { _ in true }
        try await adapter.run(machineID: "two", scope: scope, confirmed: true) { _ in true }
        let removalsBefore = await files.removals
        let gate = CloudCodexBrokerTests.Gate()
        await files.blockNextRemoval(gate)
        let clock = ContinuousClock()
        let start = clock.now
        await adapter.shutdown()
        #expect(start.duration(to: clock.now) < .seconds(6))
        #expect(adapter.pendingCleanup.count == 1)
        let one = await files.read("one", CloudCodexBroker.accessPath)
        let two = await files.read("two", CloudCodexBroker.accessPath)
        let remaining = [one, two]
        #expect(remaining.compactMap { $0 }.count == 1)
        await gate.open()
        await files.waitForRemovals(removalsBefore + 3)
        #expect(await !files.cancelledRemoval)
    }

    @Test func failedTransferCleanupDeadlineDoesNotCancelRemoteMutation() async throws {
        let (root, launch) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = Files()
        let scope = CloudCodexBrokerScope(userID: "user", teamID: nil)
        let adapter = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        try await adapter.run(machineID: "vm", scope: scope, confirmed: true) { _ in true }
        let before = await files.removals
        let gate = CloudCodexBrokerTests.Gate()
        await files.rejectCapability()
        await files.blockNextRemoval(gate)
        await #expect(throws: CloudCodexBrokerError.unsupportedMachine) {
            try await adapter.run(machineID: "vm", scope: scope, confirmed: true) { _ in true }
        }
        #expect(adapter.pendingCleanup.contains("vm"))
        await gate.open()
        await files.waitForRemovals(before + 1)
        #expect(await !files.cancelledRemoval)
        await adapter.shutdown()
    }

    @Test func newTransferPreservesOtherMachinesPendingCleanup() async throws {
        let (root, launch) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = Files()
        let scope = CloudCodexBrokerScope(userID: "user", teamID: nil)
        let adapter = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        try await adapter.run(machineID: "old", scope: scope, confirmed: true) { _ in true }
        await files.pause()
        await #expect(throws: CloudCodexBrokerError.targetOffline) { try await adapter.revoke(machineID: "old", scope: scope) }
        await files.resume()
        try await adapter.run(machineID: "new", scope: scope, confirmed: true) { _ in true }
        #expect(adapter.pendingCleanup.contains("old"))
        try await adapter.revoke(machineID: "old", scope: scope)
        #expect(adapter.pendingCleanup.isEmpty)
        await adapter.shutdown()
    }

    @Test func scopeSwitchCancelsPendingPromptWithoutDelivery() async throws {
        let (root, launch) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = Files()
        let original = CloudCodexBrokerScope(userID: "user", teamID: nil)
        var current: CloudCodexBrokerScope? = original
        let gate = CloudCodexBrokerTests.Gate()
        let adapter = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { current }, launch: { launch }, target: { _, id in files.target(id) })
        let pending = Task { try await adapter.run(machineID: "vm", scope: original, confirmed: true) { _ in await gate.pause(); return true } }
        await gate.entered()
        current = .init(userID: "other", teamID: nil)
        await adapter.scopeDidChange()
        await gate.open()
        await #expect(throws: (any Error).self) { try await pending.value }
        #expect(await files.read("vm", CloudCodexBroker.accessPath) == nil)
        await adapter.shutdown()
    }

    @Test func policyFenceStopsPendingDeliveryAndReenableReusesHolder() async throws {
        let (root, launch) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = Files()
        let scope = CloudCodexBrokerScope(userID: "user", teamID: nil)
        let gate = CloudCodexBrokerTests.Gate()
        let adapter = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        var prompts = 0
        let pending = Task {
            try await adapter.run(machineID: "vm", scope: scope, confirmed: true) { _ in
                prompts += 1
                await gate.pause()
                return true
            }
        }
        await gate.entered()
        adapter.setAvailable(false)
        await gate.open()
        await #expect(throws: (any Error).self) { try await pending.value }
        #expect(await files.read("vm", CloudCodexBroker.accessPath) == nil)

        adapter.setAvailable(true)
        try await adapter.run(machineID: "vm", scope: scope, confirmed: true) { _ in
            prompts += 1
            return true
        }
        #expect(prompts == 1)
        #expect(await files.read("vm", CloudCodexBroker.accessPath) != nil)
        await adapter.shutdown()
    }
}
