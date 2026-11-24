#if os(iOS)
import CmuxMobileLinkFFI
import CmuxMobileTransport
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "tabs-feed")

/// One of a Mac's tabs as its `tabs` service lists it: what a grid card shows before the tab
/// was ever opened on this phone. Hashes are lowercase SHA-256 hex, the name a blob is saved
/// under (``MacTabsSink/save(_:hash:mime:macID:)``).
public struct MacTabCard: Equatable, Sendable {
    public var tabID: String
    public var title: String
    /// `browser`, `terminal`, `agent`, or a kind a newer Mac names.
    public var kind: String
    public var faviconHash: String?
    public var thumbHash: String?
    public var thumbPixelSize: CGSize
    /// A terminal's screen as text, `screenColumns` by `screenRows`.
    public var screenHash: String?
    public var screenColumns: Int
    public var screenRows: Int
    /// The page-size picture, asked for when the tab opens.
    public var frameHash: String?
    public var capturedAt: Date
    /// Every blob the card shows is on the phone.
    public var filled: Bool

    init(_ row: TabsRow) {
        tabID = MacTabsFeed.tabID(wire: row.tabId)
        title = row.title
        kind = row.kind
        faviconHash = row.faviconHash
        thumbHash = row.thumbHash
        thumbPixelSize = CGSize(width: CGFloat(row.thumbW), height: CGFloat(row.thumbH))
        screenHash = row.screenHash
        screenColumns = Int(row.screenCols)
        screenRows = Int(row.screenRows)
        frameHash = row.frameHash
        capturedAt = Date(timeIntervalSince1970: TimeInterval(row.capturedAtMs) / 1000)
        filled = row.filled
    }
}

/// Where the feed keeps what a Mac sent: the phone's snapshot store.
@MainActor
public protocol MacTabsSink: AnyObject {
    /// The blobs of `macID` on disk, by hash. Told to the Mac when the link comes up, so it
    /// sends none of them again.
    /// Read after every manifest and delta: answer from memory, never by listing a folder.
    func heldBlobs(macID: String) -> [String]
    /// Bytes that hash to `hash` (checked in Rust). Saved before ``cards(_:macID:)`` or
    /// ``blobArrived(hash:tabIDs:macID:)`` names it.
    func save(_ bytes: Data, hash: String, mime: String, macID: String)
    /// The Mac's tabs, in its order (a manifest or a delta). `epoch` names the Mac's run that
    /// handed out the tab ids: what was kept by tab id under another epoch is another tab's.
    func cards(_ cards: [MacTabCard], epoch: String, macID: String)
    /// A blob of these cards is saved: they can draw it.
    func blobArrived(hash: String, tabIDs: [String], macID: String)
    /// Blobs no card names any more: delete them.
    func remove(blobs: [String], macID: String)
}

/// The phone's side of a Mac's `tabs` service (the `cmux-tab-snapshots` crate): the Mac lists
/// every open tab with the hashes of its favicon, card picture and terminal screen, and the
/// phone asks for the blobs it lacks, the cards near the open tab first. What to ask, in which
/// order, when to resume, what to delete and where a frame ends is Rust's (`TabsMirror`); this reads and writes the
/// channel and hands the bytes to the sink. A Mac whose host predates the service refuses the
/// channel, and the phone keeps the pictures it took itself.
@MainActor
public final class MacTabsFeed {
    public static let service = "tabs"

    public weak var sink: (any MacTabsSink)?
    /// The grid's card size in pixels and the screen's, sent when a link comes up.
    public var viewport = TabsViewport(cardPixelWidth: 0, cardAspect: 0, displayScale: 0, screenPixelW: 0, screenPixelH: 0)

    /// The viewport from plain values, for a caller that does not link the wire's types.
    public func setViewport(cardPixelWidth: UInt32, cardAspect: Double, displayScale: Double,
                            screenPixelW: UInt32, screenPixelH: UInt32) {
        viewport = TabsViewport(cardPixelWidth: cardPixelWidth, cardAspect: cardAspect, displayScale: displayScale,
                                screenPixelW: screenPixelW, screenPixelH: screenPixelH)
    }

    private struct Session {
        /// Which link-up of its Mac this is: a newer one replaces it.
        let id: UInt64
        let mirror: TabsMirror
        let outbox: AsyncStream<Data>.Continuation
    }
    /// The Macs whose channel is open, by Mac id.
    private var sessions: [String: Session] = [:]
    /// Each Mac's mirror, kept across link-ups: the next link-up says `resume` from its rev and
    /// the Mac answers with the deltas since, not the whole manifest again. Made at the Mac's
    /// first link-up with the blobs on disk; it goes with this feed (the signed-in coordinator).
    private var mirrors: [String: TabsMirror] = [:]
    private var lastSessionID: UInt64 = 0
    /// The cards nearest the open tab of each Mac, kept for a link that comes up later.
    private var near: [String: [String]] = [:]

    public init() {}

    /// The app's id of the tab a `tabs` row names. The wire names a tab by its daemon surface
    /// as a decimal string (PROTOCOL.md, `tabs`); the app's tab id is ``DaemonTree/tabID(surface:)``.
    nonisolated static func tabID(wire: String) -> String {
        Int(wire).map(DaemonTree.tabID(surface:)) ?? wire
    }

    /// The wire's name of the app tab `tabID`, the inverse of ``tabID(wire:)``.
    nonisolated static func wireID(tabID: String) -> String {
        guard tabID.hasPrefix("s"), let surface = Int(tabID.dropFirst()) else { return tabID }
        return String(surface)
    }

    /// The newest cards of `macID` (empty before its first manifest), kept while no link is up.
    public func cards(macID: String) -> [MacTabCard] {
        mirrors[macID]?.rows().map(MacTabCard.init) ?? []
    }

    /// `macID` was deleted: its kept cards and its place in the stream go, and an open channel
    /// of it stops at its next chunk (its session is no longer the Mac's).
    public func forget(macID: String) {
        sessions[macID]?.outbox.finish()
        sessions[macID] = nil
        mirrors[macID] = nil
        near[macID] = nil
    }

    /// The cards on screen and around them, nearest the open tab first: their blobs are asked
    /// for before the rest. Call when the grid opens, comes to rest or the open tab changes,
    /// never per scroll frame.
    public func setNear(_ tabIDs: [String], macID: String) {
        guard near[macID] != tabIDs else { return }
        near[macID] = tabIDs
        guard let session = sessions[macID] else { return }
        write(session.mirror.setNear(tabIds: tabIDs.map(Self.wireID(tabID:))), to: session)
    }

    /// `tabID` is opening: its page-size picture is asked for first.
    public func opening(tabID: String, macID: String) {
        guard let session = sessions[macID] else { return }
        write(session.mirror.wantFrame(tabId: Self.wireID(tabID: tabID)), to: session)
    }

    private func write(_ frames: [Data], to session: Session) {
        for frame in frames { session.outbox.yield(frame) }
    }

    /// Reads `macID`'s `tabs` service on `link` until the channel or the link closes.
    public func read(on link: any MacLink, macID: String) async {
        let channel: any LinkChannel
        do {
            channel = try await link.openChannel(service: Self.service, args: [:])
        } catch {
            log.info("tabs channel: \(String(describing: error), privacy: .public)")
            return
        }
        let (frames, outbox) = AsyncStream<Data>.makeStream()
        let mirror = mirrors[macID] ?? TabsMirror(held: sink?.heldBlobs(macID: macID) ?? [])
        mirrors[macID] = mirror
        lastSessionID &+= 1
        let session = Session(id: lastSessionID, mirror: mirror, outbox: outbox)
        sessions[macID] = session
        // task-owner: this read; one writer per channel keeps the frames in order, ended below.
        let writer = Task {
            for await frame in frames {
                do { try await channel.send(frame) } catch { return }
            }
        }
        defer {
            outbox.finish()
            writer.cancel()
            // A newer link's session of the same Mac stays.
            if sessions[macID]?.id == session.id { sessions[macID] = nil }
        }
        write(session.mirror.linkUp(viewport: viewport), to: session)
        if let near = near[macID], !near.isEmpty {
            write(session.mirror.setNear(tabIds: near.map(Self.wireID(tabID:))), to: session)
        }
        do {
            // The link cuts the stream where it likes: Rust keeps the partial frame and
            // answers with one event per frame a chunk completes.
            read: while let chunk = try await channel.receive() {
                // A newer link-up of this Mac shares the mirror and started its stream over:
                // this channel's bytes would land in the middle of the new channel's frames.
                guard sessions[macID]?.id == session.id else {
                    await channel.close(code: "cancelled", reason: "a newer tabs channel of this Mac took over")
                    break read
                }
                for event in session.mirror.receive(chunk: chunk) {
                    if case .broken(let reason) = event {
                        log.error("tabs stream unreadable: \(reason, privacy: .public)")
                        await channel.close(code: "protocol", reason: reason)
                        break read
                    }
                    apply(event, session: session, macID: macID)
                }
            }
            if let closed = channel.closedBy, closed.code != "eof" {
                log.info("tabs closed: \(closed.code, privacy: .public)")
            }
        } catch {
            log.info("tabs channel: \(String(describing: error), privacy: .public)")
        }
    }

    private func apply(_ event: TabsEvent, session: Session, macID: String) {
        switch event {
        case .rows(let epoch, _, let rows, let send):
            write(send, to: session)
            guard let sink else { return }
            sink.cards(rows.map(MacTabCard.init), epoch: epoch, macID: macID)
            // What no card names any more goes, once the Mac has said what it has.
            let gone = session.mirror.unreferenced(onDisk: sink.heldBlobs(macID: macID))
            if !gone.isEmpty { sink.remove(blobs: gone, macID: macID) }
        case .blob(let hash, let mime, let bytes, let fresh, let tabIDs):
            guard let sink else { return }
            if fresh { sink.save(bytes, hash: hash, mime: mime, macID: macID) }
            sink.blobArrived(hash: hash, tabIDs: tabIDs.map(Self.tabID(wire:)), macID: macID)
        case .gap(let send):
            write(send, to: session)
        case .dropped(let reason):
            log.info("tabs frame dropped: \(reason, privacy: .public)")
        case .broken:
            // Handled where the channel is read: it closes there.
            break
        }
    }
}
#endif
