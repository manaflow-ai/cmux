import AppKit
import CmuxChief

/// The app's live view of Chief's memory files: the notes (memory.jsonl)
/// re-read whenever any writer changes them (Chief through `cmux chief
/// memory add`, the user in the sheet or an editor), reported through a
/// ``ChiefMemoryWatcher`` (file-system events, no polling).
///
/// Views read ``facts`` and observe ``didChange``; its `userInfo` carries the
/// facts that change added (``addedKey``), so the transcript can say "Chief
/// will remember". Forgetting a note adds nothing.
@MainActor
final class ChiefMemoryStore {
    static let shared = ChiefMemoryStore()

    /// Posted on the main queue after the files changed.
    nonisolated static let didChange = Notification.Name("ChiefMemoryStore.didChange")
    /// `[ChiefMemoryFact]` in ``didChange``'s userInfo: the notes the change added.
    nonisolated static let addedKey = "added"

    /// Every note, oldest first.
    private(set) var facts: [ChiefMemoryFact] = []
    private(set) var memory: ChiefMemory?
    private var watcher: ChiefMemoryWatcher?

    private init() {}

    /// Starts watching once Chief's home is known; later calls only re-read.
    /// Every memory view calls it when it appears.
    func start() {
        guard watcher == nil else { return }
        guard let paths = ChiefService.shared.memoryPaths else { return }
        let memory = ChiefMemory(paths: paths)
        try? memory.ensureDefaults()
        self.memory = memory
        facts = memory.facts()
        let watcher = ChiefMemoryWatcher(paths: paths, queue: .main) {
            MainActor.assumeIsolated { ChiefMemoryStore.shared.reload() } // main-proof: the watcher's queue is .main
        }
        self.watcher = watcher
        watcher.start()
    }

    /// Re-reads the notes and tells the views.
    func reload() {
        guard let memory else { return }
        let fresh = memory.facts()
        let added = ChiefMemory.addedFacts(from: facts, to: fresh)
        facts = fresh
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: [Self.addedKey: added])
    }

    /// The newest `limit` notes, newest first.
    func recent(_ limit: Int) -> [ChiefMemoryFact] {
        Array(facts.reversed().prefix(limit))
    }

    /// Forgets a note; the watcher then reports the change to every view.
    @discardableResult
    func forget(_ id: String) -> Bool {
        start()
        guard let memory else { return false }
        do {
            try memory.forget(id)
            reload()
            return true
        } catch ChiefMemoryError.notFound {
            reload()
            return true
        } catch {
            NSSound.beep()
            return false
        }
    }

    /// Replaces a note's text in the memory browser while keeping its id and
    /// provenance. The watcher then refreshes every open memory view.
    @discardableResult
    func update(_ id: String, text: String) -> Bool {
        start()
        guard let memory else { return false }
        do {
            try memory.update(id, text: text)
            reload()
            return true
        } catch ChiefMemoryError.notFound {
            reload()
            return false
        } catch {
            NSSound.beep()
            return false
        }
    }
}
