import AppKit
import CmuxNextWakeups
public import Foundation

/// The dot glyphs of the sidebar's agent rows (`appearance.agentSignature`), read from acpmux's
/// `session/signature` and kept by session id for the life of the app: a glyph is a pure function of
/// its id, so an id is asked once. The app makes one (its composition root) and hands it to each
/// window's ``SidebarModel/agentSignatures``; a row reads it from its list on dequeue.
///
/// A row asks while it configures (``glyph(for:enabled:row:)``); the ids every row asks for before the
/// next frame go out as one request (at most ``SidebarAgentSignature/batchLimit`` ids), and the rows that
/// asked redraw when it answers. Off, nothing is asked and no frame work is queued. A failed request (no
/// acpmux, an older one) asks nothing more for ``quietAfterFailure``: a row configured after that asks again.
@MainActor
public final class SidebarAgentSignatures {
    /// Asks acpmux for the glyphs of the ids; nil when it could not (no acpmux, an error).
    public typealias Fetch = @MainActor @Sendable ([String]) async -> [String: SidebarAgentSignature]?

    private let fetch: Fetch
    /// The glyphs drawn once per id, size and scale.
    let images = SidebarAgentSignatureImage()
    /// How long a failed request keeps new ones from going out.
    static let quietAfterFailure: Duration = .seconds(30)

    private(set) var glyphs: [String: SidebarAgentSignature] = [:]
    private var queued: [String] = []
    private var queuedIDs: Set<String> = []
    private var inFlight: Set<String> = []
    /// The rows that asked for an id not read yet, redrawn when it arrives.
    private var waiting: [String: NSHashTable<WorkspaceRowView>] = [:]
    /// The next frame sends what this one's rows asked for; made the first time a row asks (on).
    private lazy var frames = FrameBatchQueue(owner: "SidebarAgentSignatures")
    private var flushQueued = false
    private var quietUntil: ContinuousClock.Instant?
    private let clock = ContinuousClock()
    /// Requests sent so far (tests: batching and the off state).
    private(set) var requestCount = 0

    public init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    /// A store that asks the acpmux at `socket()` (``asking(socket:send:)``).
    public convenience init(socket: @escaping @MainActor @Sendable () -> String?,
                            send: @escaping @Sendable (String, Data) async throws -> Data?) {
        self.init(fetch: Self.asking(socket: socket, send: send))
    }

    /// The glyph of `id` when read; nil when off, without an id, or not read yet. Not read and on, the id
    /// joins the next frame's request and `row` redraws when its glyph arrives.
    func glyph(for id: String?, enabled: Bool, row: WorkspaceRowView?) -> SidebarAgentSignature? {
        guard enabled, let id, !id.isEmpty else { return nil }
        if let glyph = glyphs[id] { return glyph }
        if let row {
            let rows = waiting[id] ?? NSHashTable<WorkspaceRowView>.weakObjects()
            rows.add(row)
            waiting[id] = rows
        }
        if !inFlight.contains(id), queuedIDs.insert(id).inserted {
            queued.append(id)
            if !flushQueued {
                flushQueued = true
                frames.enqueue { [weak self] in self?.flush() }
            }
        }
        return nil
    }

    /// Sends the queued ids, ``SidebarAgentSignature/batchLimit`` per request. Inside the quiet time after a
    /// failure it drops them instead: their rows ask again when they next configure.
    func flush() {
        flushQueued = false
        guard !queued.isEmpty else { return }
        if let quietUntil, clock.now < quietUntil {
            for id in queued { waiting[id] = nil }
            (queued, queuedIDs) = ([], [])
            return
        }
        let fetch = fetch
        while !queued.isEmpty {
            let batch = Array(queued.prefix(SidebarAgentSignature.batchLimit))
            queued.removeFirst(batch.count)
            queuedIDs.subtract(batch)
            inFlight.formUnion(batch)
            requestCount += 1
            // task-owner: SidebarAgentSignatures.flush: one session/signature request (this actor's own task, not a hop);
            // it ends with its reply or the line's deadline.
            Task { [weak self] in
                let result = await fetch(batch)
                self?.received(batch, result)
            }
        }
    }

    /// A request's answer: keeps each glyph and redraws the rows that waited for one, each once.
    func received(_ batch: [String], _ result: [String: SidebarAgentSignature]?) {
        inFlight.subtract(batch)
        guard let result else {
            quietUntil = clock.now + Self.quietAfterFailure
            for id in batch { waiting[id] = nil }
            return
        }
        quietUntil = nil
        var redraw: [ObjectIdentifier: WorkspaceRowView] = [:]
        for id in batch {
            if let glyph = result[id] { glyphs[id] = glyph }
            for row in waiting.removeValue(forKey: id)?.allObjects ?? [] { redraw[ObjectIdentifier(row)] = row }
        }
        for row in redraw.values { row.redrawLastConfiguration() }
    }

    /// A ``Fetch`` that sends one `session/signature` line to the acpmux at `socket()` (nil: none runs) through
    /// `send` (one request line in, its reply line out; it throws on a closed line or its deadline).
    public static func asking(socket: @escaping @MainActor @Sendable () -> String?,
                              send: @escaping @Sendable (String, Data) async throws -> Data?) -> Fetch {
        { ids in
            guard let path = socket() else { return nil }
            guard let reply = try? await send(path, SidebarAgentSignature.request(ids)) else { return nil }
            return SidebarAgentSignature.signatures(reply: reply)
        }
    }
}
