public import CmuxMobileHost
public import CmuxMobileWire
import CmuxNextDaemon
import CmuxTerminalStream
import Foundation

/// One phone viewer's attach (`MobileTerminalAttachment` over the daemon's
/// `TerminalAttachment`; b5-mac-host.md section 6). Maps the attach stream
/// to `terminal-snapshot-v1` frames: READY and HISTORY snapshots keep their
/// cut, live output gets the running host offset, and a READY with a new
/// grid is preceded by `terminal.size`.
public actor DaemonMobileTerminalAttachment: MobileTerminalAttachment {
    public nonisolated let opened: TerminalOpenedParams
    public nonisolated let events: AsyncStream<MobileTerminalEvent>
    private nonisolated let attachment: TerminalAttachment
    private let connection: DaemonConnection
    private var viewport: CellSize
    private var counting: Bool
    private let pump: Task<Void, Never>

    /// Waits for the attach's first event (the READY, or the byte replay of
    /// an older host) so `opened` names the real generation and grid.
    static func start(_ attachment: TerminalAttachment, connection: DaemonConnection,
                      request: MobileTerminalAttachRequest, title: String) async -> DaemonMobileTerminalAttachment {
        var iterator = attachment.events.makeAsyncIterator()
        let first = await iterator.next()
        var mapper = TerminalEventMapper()
        let replayed = first.map { mapper.map($0) } ?? [.closed]
        let opened = TerminalOpenedParams(
            generation: mapper.generation, cols: mapper.cols ?? request.viewport.cols, rows: mapper.rows ?? request.viewport.rows,
            snapshotVersion: mapper.snapshotVersion, title: title)
        // concurrency-allow: drained at once by TerminalChannelBridge, which bounds its queue by the viewer window and drops on overflow
        let (events, continuation) = AsyncStream<MobileTerminalEvent>.makeStream()
        // The first READY already set the grid in `opened`; its size event is redundant.
        for event in replayed {
            if case .size = event { continue }
            continuation.yield(event)
        }
        let ended = first == nil
        // task-owner: ends with the attach stream (detach() closes it)
        let pump = Task { [iterator, mapper] in
            var rest = iterator
            var mapper = mapper
            if !ended {
                while let event = await rest.next() {
                    for mapped in mapper.map(event) { continuation.yield(mapped) }
                }
                continuation.yield(.closed)
            }
            continuation.finish()
        }
        return DaemonMobileTerminalAttachment(attachment: attachment, connection: connection, request: request,
                                              opened: opened, events: events, pump: pump)
    }

    private init(attachment: TerminalAttachment, connection: DaemonConnection, request: MobileTerminalAttachRequest,
                 opened: TerminalOpenedParams, events: AsyncStream<MobileTerminalEvent>, pump: Task<Void, Never>) {
        self.attachment = attachment
        self.connection = connection
        self.opened = opened
        self.events = events
        self.pump = pump
        viewport = CellSize(cols: request.viewport.cols, rows: request.viewport.rows)
        counting = request.visible && request.counts
        // A hidden or preview viewer must not count toward the grid.
        if !counting { attachment.sendReleaseGeometry() }
    }

    public func write(_ input: TerminalInput) async {
        switch input.kind {
        case .bytes:
            attachment.enqueueInput(input.data)
        case .paste:
            // The host brackets by its own mode.
            try? await connection.send(attachment.surface, bytes: input.data, paste: true)
        }
    }

    public func setViewport(_ viewport: CmuxMobileWire.TerminalViewport) async {
        self.viewport = CellSize(cols: viewport.cols, rows: viewport.rows)
        if counting { attachment.sendResize(self.viewport) }
    }

    public func setPresence(visible: Bool, counts: Bool) async {
        let now = visible && counts
        guard now != counting else { return }
        counting = now
        if now {
            attachment.sendResize(viewport)
        } else {
            attachment.sendReleaseGeometry()
        }
    }

    public func requestSnapshot(_ request: MobileSnapshotRequest) async {
        attachment.requestSnapshot(reason: SnapshotRequestReason(rawValue: request.reason) ?? .gap)
    }

    public func detach() async {
        attachment.detachNow()
        pump.cancel()
    }
}
