import CmuxNextDesign
import Foundation

/// One file page document in the R96 quit hook: shared by every tab that shows the file, unsaved
/// from the first edit a page reports (`cmux.<page>.edited`), with a recovery draft written on
/// every edit through `RecoveryDraftStore`. The quit flush asks each page to save first
/// (`cmux.<page>.flush`); a document still unsaved after that is written by the host from the last
/// text a page reported, on the base hash that text was edited from, so a quit never writes over a
/// change made on disk.
final class FileQuitDocument: QuitUnsavedParticipant {
    let url: URL
    private let drafts: RecoveryDraftStore
    private let writable: () -> Bool
    private(set) var hasUnsavedChanges = false
    /// The last text a page reported, and the file hash it was edited from.
    private(set) var latestText: String?
    private(set) var baseHash: String?
    private var flushers: [UUID: () async -> Bool] = [:]
    private var work: [Task<Void, Never>] = []

    init(url: URL, drafts: RecoveryDraftStore, writable: @escaping () -> Bool) {
        self.url = url
        self.drafts = drafts
        self.writable = writable
    }

    var quitParticipantID: String { "file:local:" + url.path }
    var quitTitle: String { "\(url.lastPathComponent) (\(url.deletingLastPathComponent().lastPathComponent))" }
    var quitFlushDeadline: Duration { .seconds(3) }

    /// A page's edit: unsaved unless the text is the file's again; the draft follows.
    @discardableResult
    func edited(text: String, baseHash: String?) -> RecoveryDraftAcceptance {
        latestText = text
        self.baseHash = baseHash
        guard FileDocument.hash(Data(text.utf8)) != baseHash else {
            markClean()
            return .kept
        }
        hasUnsavedChanges = true
        return drafts.update(id: quitParticipantID, title: quitTitle, contents: Data(text.utf8), filePath: url.path)
    }

    /// A normal save wrote `hash`: clean when it is the last reported text.
    func saved(hash: String) {
        baseHash = hash
        if let latestText, FileDocument.hash(Data(latestText.utf8)) != hash { return }
        markClean()
    }

    /// The last tab closed with edits that did not save: they are dropped, and so is the draft.
    func closedWithoutSaving() {
        markClean()
    }

    /// A page that can save the document now; returns whether edits are still unsaved.
    func addFlusher(_ flush: @escaping () async -> Bool) -> () -> Void {
        let id = UUID()
        flushers[id] = flush
        return { [weak self] in self?.flushers[id] = nil }
    }

    /// Draft removals still running (tests await them).
    func settled() async {
        let running = work
        work.removeAll()
        for task in running { await task.value }
    }

    // MARK: QuitUnsavedParticipant

    func flushForQuit() async throws {
        // Each page saves through the host first (a save marks the document clean).
        for flush in Array(flushers.values) where hasUnsavedChanges {
            _ = await flush()
        }
        guard hasUnsavedChanges, let text = latestText else { return }
        let name = url.lastPathComponent
        do {
            let result = try await Self.write(text, to: url, baseHash: baseHash, inWorkspace: writable())
            baseHash = result.hash
            hasUnsavedChanges = false
        } catch .readOnly {
            throw QuitFlushError.readOnly(name)
        } catch .conflict, .deleted {
            throw QuitFlushError.conflict(name)
        } catch .failed(let reason) {
            throw QuitFlushError.failed(reason)
        }
    }

    func discardForQuit() async {
        hasUnsavedChanges = false
        latestText = nil
    }

    private func markClean() {
        hasUnsavedChanges = false
        let drafts = drafts, id = quitParticipantID
        work.append(Task { await drafts.remove(id: id) })
    }

    @concurrent private static func write(_ text: String, to url: URL, baseHash: String?,
                                          inWorkspace: Bool) async throws(FileSaveFailure) -> FileSaveResult {
        try FileDocument.save(text, to: url, baseHash: baseHash, inWorkspace: inWorkspace)
    }
}

/// The file pages' quit documents, one per canonical path, registered with the quit hook while a
/// tab that edited the file still shows it. Each such tab is a holder; the document leaves with
/// the last one.
final class FileQuitDocuments {
    /// The app's: both file pages share it, so a markdown tab and an editor tab on one file are one
    /// document.
    static let shared = FileQuitDocuments()
    private let drafts: RecoveryDraftStore
    private let registry: QuitUnsavedRegistry
    private var documents: [String: (document: FileQuitDocument, registration: QuitUnsavedRegistration, holders: Set<String>)] = [:]

    init(drafts: RecoveryDraftStore = .shared, registry: QuitUnsavedRegistry = .shared) {
        self.drafts = drafts
        self.registry = registry
    }

    func document(for url: URL, holder: String, writable: @escaping () -> Bool) -> FileQuitDocument {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if let existing = documents[path] {
            documents[path]?.holders.insert(holder)
            return existing.document
        }
        let document = FileQuitDocument(url: URL(fileURLWithPath: path), drafts: drafts, writable: writable)
        documents[path] = (document, registry.register(document), [holder])
        return document
    }

    func existing(_ url: URL) -> FileQuitDocument? {
        documents[url.standardizedFileURL.resolvingSymlinksInPath().path]?.document
    }

    /// `holder` no longer shows `url`. With no holder left, edits that did not save are dropped and
    /// the draft goes.
    func release(_ url: URL, holder: String) {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        documents[path]?.holders.remove(holder)
        guard documents[path]?.holders.isEmpty == true, let entry = documents.removeValue(forKey: path) else { return }
        if entry.document.hasUnsavedChanges { entry.document.closedWithoutSaving() }
        entry.registration.cancel()
    }
}

/// Recovered drafts that belong to the file pages: local files only (a draft never writes a remote
/// file into a local one).
enum FilePageRecovery {
    static let prefix = "file:local:"

    static func document(of draft: RecoveryDraft) -> URL? {
        guard draft.host == "local", draft.id.hasPrefix(prefix), let path = draft.filePath, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }
}
