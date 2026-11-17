@testable import CmuxChief
import Foundation
import Testing

/// The memory browser's API: documents, atomic saves, recent facts, the
/// added-facts diff, and the file-system watcher the app reloads from.
@Suite struct ChiefMemoryBrowsingTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> String {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return "m-" + String(format: "%08x", value)
        }
    }

    func makeMemory() -> (ChiefMemory, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chief-memory-browse-\(UUID().uuidString)", isDirectory: true)
        let counter = Counter()
        let memory = ChiefMemory(paths: ChiefMemoryPaths(home: ChiefHome(root: root)),
                                 now: { Date(timeIntervalSince1970: 1_792_000_000) },
                                 makeID: { counter.next() })
        return (memory, root)
    }

    @Test func documentsMapToTheirFiles() {
        let paths = ChiefMemoryPaths(directory: URL(fileURLWithPath: "/tmp/chief-m", isDirectory: true))
        #expect(ChiefMemoryDocument.person.url(in: paths) == paths.person)
        #expect(ChiefMemoryDocument.instructions.url(in: paths) == paths.instructions)
    }

    @Test func saveReplacesTheDocumentPrivatelyAndTextReadsItBack() throws {
        let (memory, root) = makeMemory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(memory.text(of: .person).isEmpty)
        #expect(memory.modificationDate(of: .person) == nil)
        try memory.save("# Me\n\n- Likes Swift\n", to: .person)
        try memory.save("Use worktrees.", to: .instructions)
        #expect(memory.text(of: .person) == "# Me\n\n- Likes Swift\n")
        #expect(memory.text(of: .instructions) == "Use worktrees.")
        #expect(memory.modificationDate(of: .person) != nil)
        let mode = try FileManager.default.attributesOfItem(atPath: memory.paths.person.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: memory.paths.directory.path)
            .filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func recentFactsAreNewestFirstAndCapped() throws {
        let (memory, root) = makeMemory()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 1...7 { try memory.add("fact \(index)", source: "cli") }
        #expect(memory.recentFacts(limit: 5).map(\.text) == ["fact 7", "fact 6", "fact 5", "fact 4", "fact 3"])
        #expect(memory.recentFacts(limit: 0).isEmpty)
        #expect(memory.recentFacts(limit: 20).count == 7)
    }

    @Test func addedFactsIgnoresForgottenOnes() throws {
        let (memory, root) = makeMemory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try memory.add("one", source: "cli")
        let before = memory.facts()
        let second = try memory.add("two", source: "cli")
        #expect(ChiefMemory.addedFacts(from: before, to: memory.facts()) == [second])
        let middle = memory.facts()
        try memory.forget(first.id)
        #expect(ChiefMemory.addedFacts(from: middle, to: memory.facts()).isEmpty)
    }

    /// What the files held each time the watcher fired, read inside its callback.
    struct Seen: Sendable {
        var ids: [String]
        var person: String
    }

    /// The watcher's reports, matched against expectations registered before each write.
    final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [UUID: (match: @Sendable (Seen) -> Bool, done: CheckedContinuation<Bool, Never>)] = [:]
        private var pending: [UUID: @Sendable (Seen) -> Bool] = [:]
        private var early: Set<UUID> = []

        /// Records one report and resumes every expectation it matches.
        func report(_ seen: Seen) {
            lock.lock()
            var resumed: [CheckedContinuation<Bool, Never>] = []
            for (id, waiter) in waiters where waiter.match(seen) {
                waiters[id] = nil
                resumed.append(waiter.done)
            }
            for (id, match) in pending where match(seen) {
                pending[id] = nil
                early.insert(id)
            }
            lock.unlock()
            for done in resumed { done.resume(returning: true) }
        }

        /// Starts expecting a report that matches; register it before the write
        /// so only reports read after the write can match. The task is true when
        /// one arrives within `seconds` (a test bound, not synchronization).
        func expect(within seconds: Double = 5, _ match: @escaping @Sendable (Seen) -> Bool) -> Task<Bool, Never> {
            let id = UUID()
            lock.lock()
            pending[id] = match
            lock.unlock()
            return Task {
                let result = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                    lock.lock()
                    if early.remove(id) != nil {
                        lock.unlock()
                        done.resume(returning: true)
                        return
                    }
                    pending[id] = nil
                    waiters[id] = (match, done)
                    lock.unlock()
                    Task {
                        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                        let timedOut = self.lock.withLock { self.waiters.removeValue(forKey: id) }
                        timedOut?.done.resume(returning: false)
                    }
                }
                return result
            }
        }
    }

    @Test func watcherReportsAddsForgetsAndSavesFromAnyWriter() async throws {
        let (memory, root) = makeMemory()
        defer { try? FileManager.default.removeItem(at: root) }
        try memory.ensureDefaults()
        let reports = Reports()
        let queue = DispatchQueue(label: "chief-memory-test")
        let watcher = ChiefMemoryWatcher(paths: memory.paths, queue: queue) {
            reports.report(Seen(ids: memory.facts().map(\.id), person: memory.text(of: .person)))
        }
        watcher.start()
        defer { watcher.stop() }
        // start() arms on its queue: wait for that before the first write.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in queue.async { done.resume() } }

        // A second memory value stands in for the CLI: another writer, same files.
        let cli = ChiefMemory(paths: memory.paths)
        let sawAdd = reports.expect { $0.ids.count == 1 }
        let added = try cli.add("prefers 14 pt font", source: "cli")
        #expect(await sawAdd.value)

        let sawForget = reports.expect { $0.ids.isEmpty }
        try cli.forget(added.id)
        #expect(await sawForget.value)

        // After the rename the watcher re-armed: a later append is still seen.
        let sawAppend = reports.expect { $0.ids.count == 1 }
        _ = try cli.add("uses codex for backend", source: "cli")
        #expect(await sawAppend.value)

        let sawSave = reports.expect { $0.person == "# About me" }
        try cli.save("# About me", to: .person)
        #expect(await sawSave.value)
    }
}
