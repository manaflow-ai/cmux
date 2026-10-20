public import Foundation
public import Observation

/// The state of one Memory Inspector tab: the Chief's view, the line a
/// person opened (zoomed into), search, the change list, and an edit or a
/// delete in progress.
///
/// Every read and change goes through its ``ChiefMemorySource``. A delete
/// asks its ``ConfirmDelete`` first (the app shows a cmux dialog); every
/// change can be undone (``undo(_:)``, ``undoLast()``). After a change the
/// model reads everything again, so the stale marks of the lines being
/// rebuilt show.
///
/// ```swift
/// let model = ChiefMemoryInspectorModel(source: source, confirmDelete: { _, _ in true })
/// await model.reload()
/// await model.open("0+8")
/// model.beginEdit(.line("0+8"))
/// model.draft = "A better summary"
/// await model.saveEdit()
/// ```
@MainActor @Observable
public final class ChiefMemoryInspectorModel {
    /// The counts at the top; nil before the first read.
    public private(set) var status: ChiefMemoryStatus?
    /// The Chief's view: the lines the next turn reads, oldest first.
    public private(set) var lines: [ChiefMemoryLine] = []
    /// The opened nodes, outermost first (the breadcrumb); the last is shown.
    public private(set) var trail: [String] = []
    /// The node shown in the detail column.
    public private(set) var detail: ChiefMemoryNode?
    /// The search field's text.
    public var query = ""
    /// The last search's hits.
    public private(set) var hits: [ChiefMemorySearchHit] = []
    /// Changes made so far, newest first.
    public private(set) var changes: [ChiefMemoryChange] = []
    /// What is being edited, with ``draft`` as its new text.
    public private(set) var editing: ChiefMemoryTarget?
    /// The edit's new text.
    public var draft = ""
    /// The last failure, shown until the next action.
    public private(set) var error: String?
    /// A call is running.
    public private(set) var busy = false

    /// Asks the person whether to delete `target`, whose current text is
    /// `text`; true deletes it.
    public typealias ConfirmDelete = @MainActor (_ target: ChiefMemoryTarget, _ text: String) async -> Bool

    private let source: any ChiefMemorySource
    private let confirmDelete: ConfirmDelete

    /// A model reading and changing memory through `source`.
    ///
    /// - Parameters:
    ///   - source: Where the memory is read and changed.
    ///   - confirmDelete: Asked before every delete; nothing is deleted on false.
    public init(source: any ChiefMemorySource, confirmDelete: @escaping ConfirmDelete) {
        self.source = source
        self.confirmDelete = confirmDelete
    }

    /// Reads the counts, the view, the change list and the opened node again.
    public func reload() async {
        await run {
            status = try await get("/api/status", as: ChiefMemoryStatus.self)
            lines = try await get("/api/view", as: ViewBody.self).lines
            changes = try await get("/api/memory/changes", as: ChangesBody.self).changes
            if let name = trail.last {
                detail = try await get("/api/node", ["name": name], as: ChiefMemoryNode.self)
            }
        }
    }

    /// Opens node `name` (a view line, a child, a search hit) and adds it to the trail.
    public func open(_ name: String) async {
        await run {
            detail = try await get("/api/node", ["name": name], as: ChiefMemoryNode.self)
            if let k = trail.firstIndex(of: name) {
                trail.removeSubrange((k + 1)...)
            } else {
                trail.append(name)
            }
        }
    }

    /// Goes to the trail's previous node, or back to the view when none.
    public func back() async {
        guard !trail.isEmpty else { return }
        trail.removeLast()
        guard let name = trail.last else {
            detail = nil
            return
        }
        await run { detail = try await get("/api/node", ["name": name], as: ChiefMemoryNode.self) }
    }

    /// Searches messages and summary lines for every word of ``query``.
    public func search() async {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else {
            hits = []
            return
        }
        await run { hits = try await get("/api/search", ["q": words], as: SearchBody.self).hits }
    }

    /// Starts editing `target` with its current text in ``draft``.
    public func beginEdit(_ target: ChiefMemoryTarget) {
        draft = text(of: target) ?? ""
        editing = target
        error = nil
    }

    /// Drops the edit.
    public func cancelEdit() {
        editing = nil
        draft = ""
    }

    /// Saves ``draft`` over the edited text, then reads everything again.
    public func saveEdit() async {
        guard let target = editing else { return }
        let text = draft
        await change("/api/memory/edit", ["target": target.queryValue, "text": text])
        if error == nil { cancelEdit() }
    }

    /// Deletes `target` once the person confirms (its text becomes a
    /// tombstone), then reads everything again. Nothing changes on a no.
    public func delete(_ target: ChiefMemoryTarget) async {
        error = nil
        guard await confirmDelete(target, text(of: target) ?? "") else { return }
        await change("/api/memory/delete", ["target": target.queryValue])
    }

    /// Undoes change `id`: every text it wrote comes back.
    public func undo(_ id: UInt64) async {
        await change("/api/memory/undo", ["change": String(id)])
    }

    /// Undoes the newest change that is not undone yet (Cmd-Z).
    public func undoLast() async {
        guard let last = changes.first(where: { !$0.undone }) else { return }
        await undo(last.id)
    }

    /// The current text of `target` as shown (the opened node's line or message, or a view line).
    public func text(of target: ChiefMemoryTarget) -> String? {
        switch target {
        case .message(let id):
            return detail?.message.flatMap { $0.id == id ? $0.text : nil }
        case .line(let name):
            if detail?.line.name == name { return detail?.line.text }
            return (detail?.children ?? []).first { $0.name == name }?.text ?? lines.first { $0.name == name }?.text
        }
    }

    private func change(_ path: String, _ query: [String: String]) async {
        await run { _ = try await source.call(path, query: query) }
        guard error == nil else { return }
        await reload()
    }

    /// Whether line `name` waits to be rebuilt after a change below it.
    public func isStale(_ name: String) -> Bool {
        status?.stale.contains(name) ?? false
    }

    private func run(_ body: () async throws -> Void) async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await body()
        } catch let failure as ChiefMemoryError {
            self.error = Self.describe(failure)
        } catch {
            self.error = Self.describe(.malformed)
        }
    }

    private func get<T: Decodable>(_ path: String, _ query: [String: String] = [:], as type: T.Type) async throws -> T {
        let data = try await source.call(path, query: query)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ChiefMemoryError.malformed
        }
    }

    static func describe(_ error: ChiefMemoryError) -> String {
        switch error {
        case .unreachable: ChiefMemoryStrings.unreachable
        case .refused(_, let message): message
        case .malformed: ChiefMemoryStrings.malformed
        }
    }

    private struct ViewBody: Decodable { var lines: [ChiefMemoryLine] }
    private struct SearchBody: Decodable { var hits: [ChiefMemorySearchHit] }
    private struct ChangesBody: Decodable { var changes: [ChiefMemoryChange] }
}
