#if DEBUG || CMUX_BENCH_HOOKS
import CmuxHomeCore
import CmuxNextCompat
import Foundation

// DEBUG and bench builds only (`CMUX_BENCH_HOOKS`): a long transcript in the real Home (the docked
// Home or a Home page tab) for the pane-resize films.
extension HomeNativeTranscriptView {
    /// `debug.home.drive {action: "seed", rows: 50 | 500 | 5000}`: FOR FILMS ONLY. Starts
    /// ``debugSeed(rows:)`` for the conversation this view shows and answers at once:
    /// `{ok, started, conversation, rows, kinds: {text, code, tool, image}, loaded}`. `loaded` is
    /// the row count the transcript holds NOW, before this seed lands. The seed is done when the
    /// transcript holds `rows` rows: `debug.home` then says `shown_count == rows` for
    /// `conversation`. Any other `rows` value, or a Home whose owner has not answered yet, is an
    /// error answer `{ok: false, error}` and starts nothing.
    ///
    /// THE SEED IS ONLY IN THE STORE (`HomeStore.debugSeed`). The owner does not have the
    /// messages: a reconnect, or a close and a new open, reads the owner's tail again. A send
    /// typed into a seeded Home gets its seq from the owner and collides with a seeded seq: do
    /// not send in a seeded Home.
    public func debugStartSeed(rows: Int?) -> [String: Any] {
        guard let rows, HomeStore.debugSeedSizes.contains(rows) else {
            return ["ok": false, "error": "rows must be 50, 500 or 5000"]
        }
        let store = binding.store
        guard store.me != nil, store.summary(conversationID) != nil else {
            return ["ok": false, "error": "the owner of the shown Home conversation has not answered yet"]
        }
        // task-owner: one seed of the shown transcript; it ends with the store's answer, and a view that is gone seeds nothing
        Task { [weak self] in _ = await self?.debugSeed(rows: rows) }
        return ["ok": true, "started": true, "conversation": conversationID.rawValue, "rows": rows,
                "kinds": HomeStore.debugSeedKinds(rows: rows), "loaded": store.transcript(for: conversationID).count]
    }

    /// FOR FILMS ONLY. Puts `rows` generated rows (50, 500 or 5000) in the transcript this view
    /// shows: text, code fences, tool rows and images, the same in every run. Every image row
    /// shows ONE generated PNG, written off the main actor and prepared once into the store's blob
    /// cache. True once the store holds the rows; false, with the transcript as it was, when the
    /// image cannot be made or the store refuses the seed.
    ///
    /// The seed is only in the store: see ``debugStartSeed(rows:)`` and `HomeStore.debugSeed`.
    @discardableResult
    public func debugSeed(rows: Int) async -> Bool {
        let store = binding.store, id = conversationID
        guard HomeStore.debugSeedSizes.contains(rows), let file = await Self.debugSeedImageFile() else { return false }
        let image = try? await store.prepareAttachment(fileURL: file).ref
        await Self.debugRemoveSeedFolder(file.deletingLastPathComponent())
        guard let image else { return false }
        return await store.debugSeed(id, rows: rows, image: image)
    }

    /// One generated PNG in a new temporary folder. Nil when it cannot be written.
    private static func debugSeedImageFile() async -> URL? {
        // task-owner: awaited here; one small file written off the main actor
        await Task.detached(priority: .userInitiated) { () -> URL? in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-home-seed-\(UUID().uuidString)")
            let file = folder.appendingPathComponent("Harbor at dusk.png")
            do {
                try FileManager.checked.createDirectory(at: folder, withIntermediateDirectories: true)
                try HomeFixtureMedia.writePNG(width: 1200, height: 900, to: file, hue: 0.08)
                return file
            } catch {
                try? FileManager.checked.removeItem(at: folder)
                return nil
            }
        }.value
    }

    /// Removes the temporary folder of ``debugSeedImageFile()``: the store keeps its own copy.
    private static func debugRemoveSeedFolder(_ folder: URL) async {
        // task-owner: awaited here; one folder removed off the main actor
        await Task.detached(priority: .utility) { () -> Void in
            try? FileManager.checked.removeItem(at: folder)
        }.value
    }
}
#endif
