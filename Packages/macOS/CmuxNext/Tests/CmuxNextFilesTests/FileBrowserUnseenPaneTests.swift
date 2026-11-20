import Foundation
import Testing
@testable import CmuxNextFiles

/// Leo, 2026-11-18: "Why should non visible thing even affect the renderer thread anyways?" (audit section 16). A Files
/// pane re-read and re-sorted its whole folder for every FSEvents batch, shown or not. A hidden pane only notes what
/// changed and catches up once when it shows; a shown one reads the changed items and splices them into place.
@MainActor
struct FileBrowserUnseenPaneTests {
    static let folder = URL(fileURLWithPath: "/cmux-memory-folder", isDirectory: true).standardizedFileURL

    /// Item `index` of the test folder: files of varied sizes and dates, some folders, some dot files.
    static func item(_ index: Int, size: Int64? = nil) -> FileEntry {
        let name = index % 23 == 0 ? ".dot-\(index)" : index % 9 == 0 ? "Folder \(index)" : "file-\(index).txt"
        return FileEntry(name: name, in: folder, kind: index % 9 == 0 ? .folder : .file, size: size ?? Int64((index &* 7919) % 100_000),
                         modified: Date(timeIntervalSince1970: Double((index &* 104_729) % 1_000_000)))
    }

    private func model(_ disk: MemoryFolder, order: FileSortOrder = FileSortOrder()) async -> FileBrowserModel {
        let model = FileBrowserModel(folder: Self.folder, sortOrder: order, lister: disk, watcher: StillWatcher())
        await model.reload()
        return model
    }

    /// What the pane should list: every item on "disk", sorted and filtered as the model does.
    private func expected(_ disk: MemoryFolder, _ model: FileBrowserModel) -> [String] {
        let matcher = FileNameMatcher(model.filterText)
        return model.sortOrder.sorted(disk.snapshot()).filter { (model.showHidden || !$0.isHidden) && matcher.matches($0.name) }.map(\.name)
    }

    /// Detector: 100 FSEvents batches and a rescan while the pane is hidden read and sort nothing; showing it catches
    /// up with one listing.
    @Test func aHiddenPaneDoesNoWorkAndCatchesUpOnceWhenShown() async {
        let disk = MemoryFolder((0..<2_000).map { Self.item($0) })
        let model = await model(disk)
        model.setShown(false)
        let before = (disk.counts(), model.fullSorts)
        for index in 2_000..<2_100 {
            disk.put(Self.item(index))
            await model.apply(.items([Self.item(index).name]), in: model.folder)
        }
        await model.apply(.rescan, in: model.folder)
        let hidden = disk.counts()
        let work = (lists: hidden.lists - before.0.lists, reads: hidden.reads - before.0.reads, sorts: model.fullSorts - before.1)
        print("files-hidden-detector batches=101 folder=2000 lists=\(work.lists) item_reads=\(work.reads) full_sorts=\(work.sorts)")
        #expect(work.lists == 0 && work.reads == 0 && work.sorts == 0, "a hidden Files pane did \(work) for changes nobody sees")
        await model.setShown(true)?.value
        #expect(disk.counts().lists - hidden.lists == 1, "showing the pane lists the folder once")
        #expect(model.entries.map(\.name) == expected(disk, model))
    }

    /// Changes noted while hidden, few enough to name, are read item by item on show, with no listing or sort.
    @Test func aHiddenPaneCatchesUpOnTheItemsThatChanged() async {
        let disk = MemoryFolder((0..<2_000).map { Self.item($0) })
        let model = await model(disk)
        model.setShown(false)
        let before = (disk.counts(), model.fullSorts)
        disk.put(Self.item(5, size: 1))
        disk.remove(Self.item(6).name)
        disk.put(Self.item(2_001))
        for name in [Self.item(5).name, Self.item(6).name, Self.item(2_001).name, Self.item(5).name] {
            await model.apply(.items([name]), in: model.folder)
        }
        #expect(disk.counts().reads == before.0.reads)
        await model.setShown(true)?.value
        let after = disk.counts()
        #expect(after.lists == before.0.lists, "no listing for three named items")
        #expect(after.reads - before.0.reads == 3, "each changed item is read once")
        #expect(model.fullSorts == before.1)
        #expect(model.entries.map(\.name) == expected(disk, model))
    }

    /// 20,000 items (a big repository's folder), shown: a batch of three changes (one changed, one new, one gone) is
    /// spliced in, timed, with no sort of the folder; the rows match a full sort in every order.
    @Test func aShownPaneSplicesChangesIntoATwentyThousandItemFolder() async {
        let count = 20_000
        let orders = [FileSortOrder(), FileSortOrder(field: .size, ascending: false), FileSortOrder(field: .modified, foldersFirst: true),
                      FileSortOrder(field: .kind)]
        for (round, order) in orders.enumerated() {
            let disk = MemoryFolder((0..<count).map { Self.item($0) })
            let model = await model(disk, order: order)
            if round == 1 { model.showHidden = true }
            if round == 2 { model.filterText = "1" }
            model.select(Self.item(30).name)
            let sorts = model.fullSorts
            var times: [Double] = []
            for batch in 0..<10 {
                let changed = Self.item(100 + batch, size: Int64(batch))
                let added = Self.item(count + batch)
                let gone = Self.item(30 + batch)
                disk.put(changed)
                disk.put(added)
                disk.remove(gone.name)
                let started = ContinuousClock.now
                await model.apply(.items([changed.name, added.name, gone.name]), in: model.folder)
                let elapsed = (ContinuousClock.now - started).components
                times.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
                #expect(model.entries.map(\.name) == expected(disk, model), "order \(order), batch \(batch)")
            }
            let median = times.sorted()[times.count / 2]
            print("files-splice-bench folder=\(count) order=\(order.field.rawValue) changes_per_batch=3 batch_ms=\(String(format: "%.2f", median)) full_sorts=\(model.fullSorts - sorts)")
            #expect(model.fullSorts == sorts, "a shown pane sorted the whole folder \(model.fullSorts - sorts) times for 10 small batches")
            #expect(model.selection.isEmpty, "a gone item leaves the selection")
        }
    }
}

/// A folder held in memory; counts its listings and single-item reads.
private final class MemoryFolder: DirectoryListing, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: FileEntry]
    private var lists = 0
    private var reads = 0

    init(_ entries: [FileEntry]) {
        items = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func list(_ folder: URL) async throws -> [FileEntry] {
        lock.withLock {
            lists += 1
            return Array(items.values)
        }
    }

    func entry(at url: URL) async -> FileEntry? {
        lock.withLock {
            reads += 1
            return items[url.lastPathComponent]
        }
    }

    func put(_ entry: FileEntry) { lock.withLock { items[entry.name] = entry } }
    func remove(_ name: String) { lock.withLock { items[name] = nil } }
    func snapshot() -> [FileEntry] { lock.withLock { Array(items.values) } }
    func counts() -> (lists: Int, reads: Int) { lock.withLock { (lists, reads) } }
}

/// A watcher that never yields (the tests call `apply`).
private struct StillWatcher: FolderWatching {
    func changes(in folder: URL) -> AsyncStream<FolderChange> { AsyncStream { _ in } }
}
