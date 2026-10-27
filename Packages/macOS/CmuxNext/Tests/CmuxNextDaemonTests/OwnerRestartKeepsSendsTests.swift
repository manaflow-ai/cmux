import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextDaemon

/// hq-6d, 2026-10-14: the DEV app's one install-key restart of its Chief owner must cut no
/// Home send (a cut send is the "Not Delivered" class). A real daemon; eight senders write
/// person messages on the app's own owner connection without a pause while the restart runs.
/// Every send must succeed, and every message must be in the restarted owner's history.
@Suite(.enabled(if: RealBinary.url != nil, "no cmux-tui binary available"), .liveDaemon, .timeLimit(.minutes(3)))
struct OwnerRestartKeepsSendsTests {
    @Test func sendsInFlightAtTheInstallKeyRestartAreDeliveredNotCut() async throws {
        let binary = try #require(RealBinary.url)
        let id = UUID().uuidString.prefix(8).lowercased()
        let root = URL(fileURLWithPath: "/tmp/cnd-send-\(id)")
        defer { try? FileManager.default.removeItem(at: root) }
        let base = ProcessInfo.processInfo.environment
        let environment = LoginEnvironment.shared.daemonEnvironment(login: nil, base: base, overrides: [:])
        let launcher = DaemonLauncher(
            work: BackgroundWork(label: "test.daemon-launcher"),
            configuration: .init(binary: binary, session: "cnd-send-\(id)", stateDirectory: root.appendingPathComponent("state"),
                                 installKey: .fixed(FrontendInstallKey.generate())),
            environment: { environment })
        let owner = DaemonConnection(endpointProvider: launcher.endpointProvider)
        do {
            _ = try await launcher.ensure()
            let old = try await owner.start()
            let created = try await owner.request(CreateConversationRequest(
                idempotencyKey: "cnd-send-\(id)", actor: "user_local", title: "Chief",
                participants: [.init(id: "user_local", kind: .human, displayName: "Tester"),
                               .init(id: "agent_mux", kind: .agent, displayName: "mux", agentClass: "mux")]))
            let conversation = created.conversation.id
            let ledger = SendLedger()
            let senders = Task {
                await withTaskGroup(of: Void.self) { group in
                    for worker in 0..<8 {
                        group.addTask {
                            var index = 0
                            // Until the restart is decided, then a few more (held ones go to the new owner).
                            while await ledger.keepSending(worker: worker) {
                                let text = "[send \(worker)-\(index)]"
                                do {
                                    _ = try await owner.request(ConversationOpRequest(
                                        conversation: conversation, idempotencyKey: "cnd-\(worker)-\(index)", actor: "user_local",
                                        transaction: nil,
                                        op: .send(clientMsgID: "cnd-\(worker)-\(index)", parts: [.text(text, runs: [])], replyTo: nil)))
                                    await ledger.sent(text)
                                } catch {
                                    await ledger.failed("\(text): \(error)")
                                }
                                index += 1
                            }
                        }
                    }
                }
            }
            await ledger.waitForFirstSends()
            let accepted = await launcher.handOffForInstallKey(identity: old, using: owner)
            #expect(accepted, "the owner refused the restart")
            await ledger.restartDecided()
            await senders.value

            // A new owner on the same state.
            let deadline = ContinuousClock.now + .seconds(60)
            var current = await owner.identity
            var ready = await owner.isReady
            while current?.pid == old.pid || current == nil || !ready {
                if ContinuousClock.now >= deadline { break }
                try await Task.sleep(for: .milliseconds(100))  // test harness poll of the reconnect
                current = await owner.identity
                ready = await owner.isReady
            }
            #expect(current != nil && current?.pid != old.pid, "no new owner took over")
            let failures = await ledger.failures
            #expect(failures.isEmpty, "\(failures.count) sends failed across the restart: \(failures.prefix(5))")
            let history = try await owner.resourceRequest({ rid in
                ResourceRequestEnvelope(id: rid, operation: "conversation.history",
                                        params: ["conversation": .string(conversation), "before_seq": .number(1_000_000_000),
                                                 "limit": .number(500)])
            }, as: JSONValue.self)
            let stored = String(describing: history)
            let sent = await ledger.texts
            #expect(sent.count >= 16, "too few sends to cover the restart: \(sent.count)")
            #expect(sent.count < 500, "more sends than one history page reads: \(sent.count)")
            let lost = sent.filter { !stored.contains($0) }
            #expect(lost.isEmpty, "\(lost.count) acknowledged sends are not in the new owner's history: \(lost.prefix(5))")
        } catch {
            await BranchDaemonHarness.shutDown(owner)
            throw error
        }
        await BranchDaemonHarness.shutDown(owner)
    }
}

/// The senders' shared record.
private actor SendLedger {
    private(set) var texts: [String] = []
    private(set) var failures: [String] = []
    private var decided = false
    private var firstWaiters: [CheckedContinuation<Void, Never>] = []

    private var after: [Int: Int] = [:]

    /// Each sender goes on until the restart is decided, then sends 5 more.
    func keepSending(worker: Int) -> Bool {
        guard decided else { return true }
        after[worker, default: 0] += 1
        return after[worker, default: 0] <= 5
    }

    func restartDecided() { decided = true }

    func sent(_ text: String) {
        texts.append(text)
        if texts.count == 8 { firstWaiters.forEach { $0.resume() }; firstWaiters.removeAll() }
    }

    func failed(_ what: String) {
        failures.append(what)
        // Sends that fail before the restart must not leave the test waiting.
        if failures.count == 8 { firstWaiters.forEach { $0.resume() }; firstWaiters.removeAll() }
    }

    /// Returns once eight sends went through (the senders are running).
    func waitForFirstSends() async {
        if texts.count >= 8 || failures.count >= 8 { return }
        await withCheckedContinuation { firstWaiters.append($0) }
    }
}
