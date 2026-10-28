import AppKit
import CmuxNextAccounts
@testable import CmuxNextApp
import CmuxNextCodeRouter
import CmuxNextCompat
import CmuxNextWakeups
import Darwin
import Foundation
import Testing

/// Settings > Accounts' pasted key: its Keychain save and delete run on the app's system lane, never on the main
/// thread, and the answer reaches the main thread through the main-thread scheduler after the write
/// (plans/cmux-next/chrome-parity/p02-threads.md, tasks 054-055). A fake key store records the thread of each call.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct AccountsKeyLaneTests {
    nonisolated static let laneLabel = "test.accounts-keys"

    /// A key store in memory that records whether each call ran on the main thread or a system lane slot.
    nonisolated final class FakeKeys: ProviderKeyStoring, Sendable {
        struct Call: Sendable, Equatable {
            var name: String
            var onMain: Bool
            var onSystemLane: Bool
        }

        struct Refused: Error {}

        private let state = Mutex<(saved: Set<AIProvider>, calls: [Call])>(([], []))
        private let refuses: Bool

        init(refuses: Bool = false) {
            self.refuses = refuses
        }

        var calls: [Call] { state.withLock { $0.calls } }
        var saved: Set<AIProvider> { state.withLock { $0.saved } }

        func savedProviders() -> Set<AIProvider> {
            record("savedProviders")
            return saved
        }

        func save(_ key: String, for provider: AIProvider) throws {
            record("save")
            if refuses { throw Refused() }
            state.withLock { _ = $0.saved.insert(provider) }
        }

        func key(for provider: AIProvider) throws -> String? {
            record("key")
            return nil
        }

        func delete(for provider: AIProvider) throws {
            record("delete")
            state.withLock { _ = $0.saved.remove(provider) }
        }

        /// A system lane slot runs on a queue labelled `<lanes' label>.system...` (BackgroundWork's `label`).
        private func record(_ name: String) {
            let label = String(cString: __dispatch_queue_get_label(nil))
            let call = Call(name: name, onMain: pthread_main_np() != 0, onSystemLane: label.hasPrefix(AccountsKeyLaneTests.laneLabel + ".system"))
            state.withLock { $0.calls.append(call) }
        }
    }

    /// The answers `done` got, and whether each came on the main thread.
    final class Answers {
        var failures: [Bool] = []
        var onMain = true

        func note(_ error: (any Error)?) {
            failures.append(error != nil)
            onMain = onMain && pthread_main_np() != 0
        }
    }

    private func make(_ keys: FakeKeys) -> (AppServices, AccountsService) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]), work: BackgroundWork(label: Self.laneLabel))
        return (services, AccountsService(services: services, keys: keys))
    }

    /// Runs main run loop passes (where a reply posted from a lane lands) until `done` or 5 s.
    private static func spinMainRunLoop(until done: () -> Bool) {
        let end = Date(timeIntervalSinceNow: 5)
        while !done(), Date() < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    @Test func aPastedKeyIsSavedOnTheSystemLaneAndAnsweredOnMain() {
        let keys = FakeKeys()
        let (services, accounts) = make(keys)
        let answers = Answers()
        accounts.saveKey("sk-test", for: .openAI) { answers.note($0) }
        #expect(answers.failures.isEmpty, "the save answered before its Keychain write")
        Self.spinMainRunLoop { !answers.failures.isEmpty }

        #expect(answers.failures == [false])
        #expect(answers.onMain)
        #expect(keys.saved == [.openAI])
        #expect(keys.calls == [FakeKeys.Call(name: "save", onMain: false, onSystemLane: true)])
        withExtendedLifetime(services) {}
    }

    @Test func aRefusedSaveAnswersItsErrorOnMain() {
        let keys = FakeKeys(refuses: true)
        let (services, accounts) = make(keys)
        let answers = Answers()
        accounts.saveKey("sk-test", for: .openAI) { answers.note($0) }
        Self.spinMainRunLoop { !answers.failures.isEmpty }

        #expect(answers.failures == [true])
        #expect(answers.onMain)
        #expect(keys.saved.isEmpty)
        #expect(keys.calls.allSatisfy { !$0.onMain && $0.onSystemLane })
        withExtendedLifetime(services) {}
    }

    @Test func aSavedKeyIsDeletedOnTheSystemLane() {
        let keys = FakeKeys()
        let (services, accounts) = make(keys)
        let answers = Answers()
        accounts.saveKey("sk-test", for: .openAI) { answers.note($0) }
        accounts.deleteSavedKey(for: .openAI) { answers.note($0) }
        Self.spinMainRunLoop { answers.failures.count == 2 }

        #expect(answers.failures == [false, false])
        #expect(answers.onMain)
        #expect(Set(keys.calls.map(\.name)) == ["save", "delete"])
        #expect(keys.calls.allSatisfy { !$0.onMain && $0.onSystemLane })
        withExtendedLifetime(services) {}
    }
}
