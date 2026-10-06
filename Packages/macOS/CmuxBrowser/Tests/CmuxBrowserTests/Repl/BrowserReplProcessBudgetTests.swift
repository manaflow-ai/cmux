import Foundation
import Testing

@testable import CmuxBrowser

/// r23 native#3: each session had only its own ledger (512 MiB) and its own
/// 8 MiB thread stack, so the 32 sessions an instance allows could hold
/// about 16 GiB together. Every session's ledger also reserves in one
/// process-wide ledger (``BrowserReplResourceLedger/process``); these tests
/// give the sessions their own small one.
@Suite("Browser REPL process-wide memory budget", .serialized)
struct BrowserReplProcessBudgetTests {
    private func makeSession(_ process: BrowserReplResourceLedger) -> BrowserReplSession {
        BrowserReplSession(
            id: "budget-\(UUID().uuidString)",
            cwd: browserReplTestWorkingDirectory,
            bundle: BrowserReplRuntimeBundle(replScripts: [], agentScripts: []),
            driver: RecordingReplDriver(),
            processLedger: process,
            executionTimeLimitSupported: BrowserReplWatchdog.isSupported
        )
    }

    @Test("Sessions together hold at most the process budget; a refusal leaves the others whole")
    func sessionsShareOneBudget() throws {
        let stack = BrowserReplJSThread.stackSize
        let process = BrowserReplResourceLedger(limits: BrowserReplResourceLimits.process.with(.processMemoryBytes, 2 * stack + (48 << 20)))
        let first = makeSession(process)
        let second = makeSession(process)
        #expect(!first.isClosed && !second.isClosed)
        #expect(process.held(.processMemoryBytes) == 2 * stack, "each session holds its thread's stack")

        #expect(first.ledger.reserve(40 << 20, of: .requestBytes, each: .max) == nil)
        let refused = try #require(second.ledger.reserve(16 << 20, of: .requestBytes, each: .max))
        #expect(refused.resource == .processMemoryBytes)
        #expect(refused.message.contains("all REPL sessions"), "\(refused.message)")
        #expect(second.ledger.held(.requestBytes) == 0, "a refused reservation holds nothing")
        #expect(first.ledger.held(.requestBytes) == 40 << 20, "the refusal took nothing from the other session")

        first.ledger.release(40 << 20, of: .requestBytes)
        #expect(second.ledger.reserve(16 << 20, of: .requestBytes, each: .max) == nil, "released memory is room for any session")
        second.ledger.release(16 << 20, of: .requestBytes)

        first.close()
        second.close()
        // close() gives back the stack and what its holders had not released.
        #expect(process.held(.processMemoryBytes) == 0, "closed sessions still hold \(process.held(.processMemoryBytes))")
    }

    @Test("A session the budget cannot give a thread fails its cells with the limit and takes no registry slot")
    func aSessionPastTheBudgetDoesNotStart() async throws {
        let process = BrowserReplResourceLedger(limits: BrowserReplResourceLimits.process.with(.processMemoryBytes, BrowserReplJSThread.stackSize))
        let kept = makeSession(process)
        defer { kept.close() }
        let registry = BrowserReplSessionRegistry()
        let key = BrowserReplSessionKey(workspaceID: UUID(), name: "over")
        let session = try registry.session(for: key) { _ in makeSession(process) }
        #expect(session.isClosed)
        let result = await session.evaluate(code: "1")
        #expect(result.error?.contains("could not start") == true, "\(result.error ?? "no error")")
        #expect(result.error?.contains("all REPL sessions") == true, "\(result.error ?? "no error")")
        #expect(registry.list(workspaceID: nil).isEmpty, "a session that never started holds a slot")
        #expect(process.held(.processMemoryBytes) == BrowserReplJSThread.stackSize, "the refused session took a share")
    }
}
