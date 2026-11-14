import Foundation
import Observation

/// One saved New Task draft, as the drafts list shows it and as it is written to disk: what the
/// composer held, its photos by id (their bytes live in their own files), and when it was saved.
public struct SavedTaskDraft: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var updatedAt: Date
    public var prompt: String
    public var imageIDs: [String]
    /// The files by id and name (their bytes live in their own files, as the photos').
    public var files: [SavedTaskFile]
    public var picks: [TaskAgentPick]
    public var macID: String?
    public var directory: String?
    public var name: String
    public var launch: TaskLaunch

    public struct SavedTaskFile: Codable, Hashable, Sendable {
        public var id: String
        public var name: String
    }

    public init(_ draft: TaskDraft, updatedAt: Date) {
        id = draft.id
        self.updatedAt = updatedAt
        prompt = draft.prompt
        imageIDs = draft.images.map(\.id)
        files = draft.files.map { SavedTaskFile(id: $0.id, name: $0.name) }
        picks = draft.picks
        macID = draft.macID
        directory = draft.directory
        name = draft.name
        launch = draft.launch
    }

    private enum CodingKeys: String, CodingKey {
        case id, updatedAt, prompt, imageIDs, files, picks, macID, directory, name, launch
    }

    /// A draft written before files and the launch choice were kept reads with none and a chat.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        prompt = try c.decode(String.self, forKey: .prompt)
        imageIDs = try c.decodeIfPresent([String].self, forKey: .imageIDs) ?? []
        files = try c.decodeIfPresent([SavedTaskFile].self, forKey: .files) ?? []
        picks = try c.decodeIfPresent([TaskAgentPick].self, forKey: .picks) ?? []
        macID = try c.decodeIfPresent(String.self, forKey: .macID)
        directory = try c.decodeIfPresent(String.self, forKey: .directory)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        launch = try c.decodeIfPresent(TaskLaunch.self, forKey: .launch) ?? .chat
    }

    /// Every bytes file this draft names: its photos and its files.
    var blobIDs: [String] { imageIDs + files.map(\.id) }

    /// The list's first line: the prompt's first line, else the name, else "No prompt yet".
    public var title: String {
        let line = prompt.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isNewline).first
            .map(String.init) ?? ""
        if !line.isEmpty { return line }
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? "No prompt yet" : typed
    }

    public var hasPrompt: Bool { !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The same content, whenever it was saved (a resumed draft left unchanged is not "changed").
    func sameContent(as other: SavedTaskDraft) -> Bool {
        var a = self, b = other
        a.updatedAt = .distantPast
        b.updatedAt = .distantPast
        return a == b
    }
}

/// The saved New Task drafts, newest first: the composer saves the one it holds when it is left
/// with something in it, and the drafts list resumes or deletes them. Kept on disk (an index
/// and one file per photo, written off the main actor) or, with no folder, in memory.
@MainActor
@Observable
public final class TaskDraftStore {
    public private(set) var drafts: [SavedTaskDraft] = []
    /// The index was read (a list opened before shows its rows once it is).
    public private(set) var isLoaded = false

    /// The most drafts kept: saving past it drops the oldest.
    public static let limit = 40

    @ObservationIgnored private let disk: TaskDraftDisk?
    /// Photo bytes by id, for a store with no folder (and as written, until read back).
    @ObservationIgnored private var memoryImages: [String: Data] = [:]
    /// The last disk write: each waits for the one before, so they land in the order made.
    @ObservationIgnored private var writeTail: Task<Void, Never>?

    /// `directory` nil keeps the drafts in memory (tests, sample data).
    public init(directory: URL?) {
        disk = directory.map(TaskDraftDisk.init)
        if disk == nil { isLoaded = true }
    }

    /// Reads the saved drafts (once; later calls do nothing).
    public func load() async {
        guard !isLoaded, let disk else { return }
        let read = await disk.readIndex()
        guard !isLoaded else { return }
        // A save made before the read finished wins over its older copy on disk.
        let saved = Set(drafts.map(\.id))
        drafts = (drafts + read.filter { !saved.contains($0.id) }).sorted { $0.updatedAt > $1.updatedAt }
        isLoaded = true
    }

    public func entry(_ id: UUID) -> SavedTaskDraft? { drafts.first { $0.id == id } }

    /// Saves `draft` under its id (replacing its earlier copy), newest first. An empty draft is
    /// deleted instead: nothing in it is worth keeping.
    public func save(_ draft: TaskDraft, now: Date = Date()) {
        guard !draft.isEmpty else {
            delete([draft.id])
            return
        }
        let entry = SavedTaskDraft(draft, updatedAt: now)
        drafts.removeAll { $0.id == draft.id }
        // Newest first, by when each was saved.
        drafts.insert(entry, at: drafts.firstIndex { $0.updatedAt <= entry.updatedAt } ?? drafts.endIndex)
        if drafts.count > Self.limit { drafts.removeLast(drafts.count - Self.limit) }
        let blobs = draft.images.map { TaskImage(id: $0.id, data: $0.data) } + draft.files.map { TaskImage(id: $0.id, data: $0.data) }
        for blob in blobs where memoryImages[blob.id] == nil { memoryImages[blob.id] = blob.data }
        persist(newImages: blobs)
    }

    public func delete(_ ids: Set<UUID>) {
        guard drafts.contains(where: { ids.contains($0.id) }) else { return }
        drafts.removeAll { ids.contains($0.id) }
        persist(newImages: [])
    }

    /// The draft with its photos, to put back in the composer; nil when it is gone.
    public func draft(_ id: UUID) async -> TaskDraft? {
        guard let entry = entry(id) else { return nil }
        var images: [TaskImage] = []
        for imageID in entry.imageIDs {
            if let data = memoryImages[imageID] {
                images.append(TaskImage(id: imageID, data: data))
            } else if let data = await disk?.readImage(imageID) {
                images.append(TaskImage(id: imageID, data: data))
            }
        }
        var files: [TaskFile] = []
        for file in entry.files {
            if let data = memoryImages[file.id] {
                files.append(TaskFile(id: file.id, name: file.name, data: data))
            } else if let data = await disk?.readImage(file.id) {
                files.append(TaskFile(id: file.id, name: file.name, data: data))
            }
        }
        return TaskDraft(id: entry.id, prompt: entry.prompt, images: images, files: files, picks: entry.picks, macID: entry.macID,
                         directory: entry.directory, name: entry.name, launch: entry.launch)
    }

    /// Writes the index and the photos not yet on disk, then removes the photo files no draft
    /// names. In memory: drops the bytes no draft names.
    private func persist(newImages: [TaskImage]) {
        let kept = Set(drafts.flatMap(\.blobIDs))
        guard let disk else {
            memoryImages = memoryImages.filter { kept.contains($0.key) }
            return
        }
        let index = drafts
        let writes = newImages.filter { kept.contains($0.id) }
        // Only the bytes still waiting for their write stay in memory.
        memoryImages = memoryImages.filter { kept.contains($0.key) }
        let previous = writeTail
        writeTail = Task { [weak self] in
            await previous?.value
            await disk.write(index: index, images: writes, keeping: kept)
            guard let self else { return }
            for image in writes { self.memoryImages[image.id] = nil }
        }
    }

    /// Waits until every save and delete made so far is on disk.
    public func flush() async {
        await writeTail?.value
    }
}

/// The drafts folder: `index.json` and `images/<id>`. One actor, so writes happen in order and
/// never on the main actor.
actor TaskDraftDisk {
    let root: URL
    private var images: URL { root.appendingPathComponent("images", isDirectory: true) }
    private var index: URL { root.appendingPathComponent("index.json") }

    init(_ root: URL) {
        self.root = root
    }

    func readIndex() -> [SavedTaskDraft] {
        guard let data = try? Data(contentsOf: index) else { return [] }
        return (try? JSONDecoder().decode([SavedTaskDraft].self, from: data)) ?? []
    }

    func readImage(_ id: String) -> Data? {
        guard Self.isSafeName(id) else { return nil }
        return try? Data(contentsOf: images.appendingPathComponent(id))
    }

    func write(index drafts: [SavedTaskDraft], images new: [TaskImage], keeping kept: Set<String>) {
        let files = FileManager.default
        try? files.createDirectory(at: images, withIntermediateDirectories: true)
        for image in new where Self.isSafeName(image.id) {
            try? image.data.write(to: images.appendingPathComponent(image.id), options: [.atomic, .completeFileProtection])
        }
        if let data = try? JSONEncoder().encode(drafts) {
            try? data.write(to: index, options: [.atomic, .completeFileProtection])
        }
        for name in (try? files.contentsOfDirectory(atPath: images.path)) ?? [] where !kept.contains(name) {
            try? files.removeItem(at: images.appendingPathComponent(name))
        }
    }

    /// A photo id is a file name: letters, digits and dashes only (never a path).
    static func isSafeName(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }
}
