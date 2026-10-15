public import CmuxNextDaemon
import Foundation
public import Observation

/// The Home list's rows as the local conversation owner derives them (`home-inbox`, home-inbox-v1):
/// kind, name (a Chief's registry name), unread, the person's pins and marks, in list order. The
/// Messages list maps these rows and keeps no rules of its own, so it shows what the Channels page
/// shows. `rows` is nil while the owner does not serve `home-inbox` (an older daemon): the list
/// then keeps its own path. Pins and marks are written with `conversation-inbox-op`.
@Observable @MainActor
public final class HomeInboxSource {
    /// The owner's rows in list order; nil without an owner that serves `home-inbox`.
    public private(set) var rows: [HomeInboxRequest.Row]?
    @ObservationIgnored private var connection: DaemonConnection?
    /// Bumped by each new connection: a reply for an older one is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var readAgain = false
    /// Batches of inbox ops not answered yet: a read meanwhile would undo the local edit, so it is
    /// dropped and one read runs after the last answer.
    @ObservationIgnored private var pendingWrites = 0

    /// Owner events after which the rows are asked again (coalesced), besides `conversation-changed`
    /// (spec `home-inbox`). The list shows no Chief state, so typing and run changes are not among them.
    public static let rowEvents: Set<String> = ["conversation-inbox-changed", "chief-changed"]

    public init() {}

    /// A new owner connection (or none): the rows are read again from it. The last rows stay while
    /// the owner reconnects, so the list does not fall back to the old order and back.
    public func connectionChanged(_ connection: DaemonConnection?) {
        self.connection = connection
        generation += 1
        refresh()
    }

    /// One owner event: a change that can move a row asks for the rows again.
    public func note(_ event: DaemonEvent) {
        switch event {
        case .conversationChanged: refresh()
        case .unknown(let name, _) where Self.rowEvents.contains(name): refresh()
        default: break
        }
    }

    /// Reads the rows; one read at a time, and a request during a read runs one more read after it.
    public func refresh() {
        guard connection != nil else { return }
        if reading { readAgain = true; return }
        reading = true
        // task-owner: one home-inbox read (and one more per request made during it); ends with its reply
        Task { [weak self] in
            while let self, let connection = self.connection {
                let generation = self.generation
                readAgain = false
                let read = await Self.read(connection)
                guard generation == self.generation else { continue }
                switch read {
                case .unsupported: if rows != nil { rows = nil }
                case .rows(let next): if pendingWrites == 0, rows != next { rows = next }
                case .failed: break
                }
                if !readAgain { break }
            }
            self?.reading = false
        }
    }

    private enum Read: Sendable { case unsupported, rows([HomeInboxRequest.Row]), failed }

    private static func read(_ connection: DaemonConnection) async -> Read {
        guard await connection.identity?.supports(DaemonCapabilities.shared.homeInbox) == true else { return .unsupported }
        guard let reply = try? await connection.request(HomeInboxRequest()) else { return .failed }
        return .rows(reply.rows)
    }

    // MARK: Writes (the person's own list state; the owner's rows follow with its event)

    /// Pins (after the person's other pins) or unpins `id`.
    public func setPinned(_ on: Bool, _ id: String) {
        edit(id) { row in
            row.pinned = on
            row.pinPosition = on ? Self.now() : nil
        }
        if on, let index = rows?.firstIndex(where: { $0.id == id }), var list = rows {
            // Shown at the end of the pinned rows until the owner's rows come back.
            let row = list.remove(at: index)
            list.insert(row, at: list.firstIndex { !$0.pinned } ?? list.endIndex)
            rows = list
        }
        write([ConversationInboxOpRequest(conversation: id, op: .pin(on, position: on ? Self.now() : nil))])
    }

    /// The pinned rows in `order` (a drag in the pinned grid): each gets a position in that order.
    public func place(_ order: [String]) {
        guard var list = rows else { return }
        let base = Self.now()
        let placed = Set(order)
        let pinned = order.compactMap { id in list.first { $0.id == id } }.enumerated().map { index, row in
            var row = row
            row.pinned = true
            row.pinPosition = base + UInt64(index)
            return row
        }
        list.removeAll { placed.contains($0.id) }
        list.insert(contentsOf: pinned, at: list.firstIndex { !$0.pinned } ?? list.endIndex)
        rows = list
        write(pinned.map { ConversationInboxOpRequest(conversation: $0.id, op: .pin(true, position: $0.pinPosition)) })
    }

    /// Marks `id` unread (Mark as Unread) or clears the mark; nothing is sent when it already is so.
    public func setMarkedUnread(_ on: Bool, _ id: String) {
        guard let row = rows?.first(where: { $0.id == id }), row.markedUnread != on else { return }
        edit(id) { $0.markedUnread = on }
        write([ConversationInboxOpRequest(conversation: id, op: .markUnread(on))])
    }

    private func edit(_ id: String, _ change: (inout HomeInboxRequest.Row) -> Void) {
        guard var list = rows, let index = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[index])
        rows = list
    }

    /// Sends the ops in order, then reads the rows again (the owner's answer wins over the local edit).
    private func write(_ requests: [ConversationInboxOpRequest]) {
        guard let connection, !requests.isEmpty else { return }
        pendingWrites += 1
        // task-owner: one batch of inbox ops; ends with the last reply
        Task { [weak self] in
            for request in requests { _ = try? await connection.request(request) }
            guard let self else { return }
            pendingWrites -= 1
            if pendingWrites == 0 { refresh() }
        }
    }

    /// Milliseconds since 1970: the position the Channels page gives a pin too, so both views'
    /// pins sort by when they were made.
    private static func now() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
}
