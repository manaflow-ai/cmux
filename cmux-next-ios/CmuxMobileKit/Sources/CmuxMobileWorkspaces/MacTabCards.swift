#if os(iOS)
import Foundation
import Observation
import UIKit

/// What a Mac's `tabs` service last said of one tab (the `cmux-tab-snapshots` crate's row).
/// Hashes are lowercase SHA-256 hex: the names its blobs are stored under.
public struct MacCardInfo: Codable, Equatable, Sendable {
    public var title: String
    /// `browser`, `terminal`, `agent`, or a kind a newer Mac names.
    public var kind: String
    public var faviconHash: String?
    public var thumbHash: String?
    /// A terminal's screen as text, `screenColumns` by `screenRows`.
    public var screenHash: String?
    public var screenColumns: Int
    public var screenRows: Int
    public var capturedAtMs: Int64

    public init(title: String, kind: String, faviconHash: String? = nil, thumbHash: String? = nil,
                screenHash: String? = nil, screenColumns: Int = 0, screenRows: Int = 0, capturedAtMs: Int64 = 0) {
        self.title = title
        self.kind = kind
        self.faviconHash = faviconHash
        self.thumbHash = thumbHash
        self.screenHash = screenHash
        self.screenColumns = screenColumns
        self.screenRows = screenRows
        self.capturedAtMs = capturedAtMs
    }

    /// The blobs the card shows.
    var hashes: [String] { [faviconHash, thumbHash, screenHash].compactMap { $0 } }
}

/// What one Mac folder holds, read in one pass off the main thread.
struct MacCardDisk: Sendable {
    var cards: [String: MacCardInfo] = [:]
    var names: [String] = []
    /// The epoch the rows were sent under (empty: none kept).
    var epoch = ""
}

/// The Mac's blobs and rows on disk: one folder per account and Mac beside the phone's own
/// pictures, so what the Mac is told the phone holds (`have`) and what the phone deletes when
/// the Mac's rows stop naming it are only ever the Mac's blobs, never a picture the phone drew.
extension TabSnapshotStore {
    static func isHash(_ name: String) -> Bool {
        name.utf8.count == 64 && name.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    func macDirectory(accountID: String, macID: String) -> URL {
        // The key's own encoding, so no id reaches a path unencoded.
        let name = TabSnapshotKey(accountID: accountID, macID: macID, tabID: "").fileComponent
        return directory.appendingPathComponent("mac-\(name)", isDirectory: true)
    }

    func macBlobURL(_ hash: String, accountID: String, macID: String) -> URL? {
        guard Self.isHash(hash) else { return nil }
        return macDirectory(accountID: accountID, macID: macID).appendingPathComponent("blob-\(hash)")
    }

    public func macBlob(_ hash: String, accountID: String, macID: String) -> Data? {
        macBlobURL(hash, accountID: accountID, macID: macID).flatMap { try? Data(contentsOf: $0) }
    }

    /// `data` hashes to `hash` (the feed's Rust checked it).
    public func putMacBlob(_ data: Data, hash: String, accountID: String, macID: String) {
        guard let url = macBlobURL(hash, accountID: accountID, macID: macID) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    public func removeMacBlobs(_ hashes: [String], accountID: String, macID: String) {
        for hash in hashes {
            if let url = macBlobURL(hash, accountID: accountID, macID: macID) { try? FileManager.default.removeItem(at: url) }
        }
    }

    func macCardsURL(accountID: String, macID: String) -> URL {
        macDirectory(accountID: accountID, macID: macID).appendingPathComponent("cards.json")
    }

    public func macCards(accountID: String, macID: String) -> [String: MacCardInfo] {
        guard let data = try? Data(contentsOf: macCardsURL(accountID: accountID, macID: macID)) else { return [:] }
        return (try? JSONDecoder().decode([String: MacCardInfo].self, from: data)) ?? [:]
    }

    public func putMacCards(_ cards: [String: MacCardInfo], accountID: String, macID: String) {
        let url = macCardsURL(accountID: accountID, macID: macID)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cards) { try? data.write(to: url, options: .atomic) }
    }

    func macEpochURL(accountID: String, macID: String) -> URL {
        macDirectory(accountID: accountID, macID: macID).appendingPathComponent("epoch")
    }

    /// The epoch the kept rows were sent under (empty: none kept).
    public func macEpoch(accountID: String, macID: String) -> String {
        (try? String(contentsOf: macEpochURL(accountID: accountID, macID: macID), encoding: .utf8)) ?? ""
    }

    public func putMacEpoch(_ epoch: String, accountID: String, macID: String) {
        let url = macEpochURL(accountID: accountID, macID: macID)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(epoch.utf8).write(to: url, options: .atomic)
    }

    func macDisk(accountID: String, macID: String) -> MacCardDisk {
        let folder = macDirectory(accountID: accountID, macID: macID)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let names = files.compactMap { $0.hasPrefix("blob-") ? String($0.dropFirst(5)) : nil }.filter(Self.isHash)
        return MacCardDisk(cards: macCards(accountID: accountID, macID: macID), names: names,
                           epoch: macEpoch(accountID: accountID, macID: macID))
    }

    /// The tab's newest picture: the phone's own capture or the Mac's thumbnail.
    public func newestPicture(_ key: TabSnapshotKey) -> (data: Data, capturedAtMs: Int64)? {
        let own = record(key).flatMap { record in blob(record.thumbHash).map { (data: $0, capturedAtMs: record.capturedAtMs) } }
        let card = macCards(accountID: key.accountID, macID: key.macID)[key.tabID]
        let mac = card.flatMap { card in
            card.thumbHash.flatMap { macBlob($0, accountID: key.accountID, macID: key.macID) }
                .map { (data: $0, capturedAtMs: card.capturedAtMs) }
        }
        guard let own else { return mac }
        guard let mac, mac.capturedAtMs > own.capturedAtMs else { return own }
        return mac
    }
}

/// One tab as the Mac last described it, decoded: what its card reads besides its picture
/// (`TabSnapshotEntry`). Observed per tab. A favicon or a screen stays until its replacement
/// is here, so a card never blanks between two versions.
@MainActor
@Observable
public final class MacCardEntry {
    public fileprivate(set) var info: MacCardInfo?
    public fileprivate(set) var favicon: UIImage?
    /// A terminal's screen as text, `info.screenColumns` by `info.screenRows`.
    public fileprivate(set) var screen: String?
    @ObservationIgnored fileprivate var shownFavicon: String?
    @ObservationIgnored fileprivate var shownScreen: String?
    @ObservationIgnored fileprivate var shownThumb: String?
}

/// Every tab of every linked Mac as its `tabs` service pushes it: title, kind, favicon,
/// thumbnail and terminal screen, kept on disk so the grid opens filled on a cold launch,
/// before any link is up (Leo, 2026-11-22: "if the phone is simply browsing the opened tabs on
/// the mac, there should be no reason for there to be so many blank favicons and blank previews
/// and blank pages"). The feed (`MacTabsFeed`) writes here through the shell; cards read
/// `entry`. Thumbnails are shown through `TabCardSnapshots`, which bounds decoded pictures.
@MainActor
public final class MacTabCards {
    public static let shared = MacTabCards()

    public var store: TabSnapshotStore
    let snapshots: TabCardSnapshots
    private var entries: [TabSnapshotKey: MacCardEntry] = [:]
    /// The Mac's blobs on disk by Mac id, for the signed-in account.
    private var held: [String: Set<String>] = [:]
    private var heldAccount: String?
    private var warmed: Set<String> = []
    /// The epoch each Mac's rows in `entries` were sent under, by Mac id (empty: kept rows of
    /// an unknown epoch). Tab ids last one epoch: the same id under another names another tab.
    private var epochs: [String: String] = [:]
    /// Bytes just received, until their file is written.
    private var arriving: [String: Data] = [:]
    /// The cards nearest the open tab of a Mac, nearest first: the shell hands them to the
    /// feed, which asks for their blobs before the rest.
    public var near: ((_ tabIDs: [String], _ macID: String) -> Void)?
    /// Disk reads finished (tests).
    public private(set) var loads = 0
    /// Per card, who waits for its first screen (`whenScreen`): one each, the newest asker.
    private var screenWaiters: [TabSnapshotKey: @MainActor (String) -> Void] = [:]

    public init(store: TabSnapshotStore = .standard, snapshots: TabCardSnapshots = .shared) {
        self.store = store
        self.snapshots = snapshots
    }

    /// The signed-in account, and what was known of another account forgotten.
    private func account() -> String? {
        guard let account = snapshots.accountID?(), !account.isEmpty else { return nil }
        if heldAccount != account {
            heldAccount = account
            held = [:]
            warmed = []
            epochs = [:]
            arriving = [:]
            entries = [:]
            screenWaiters = [:]
        }
        return account
    }

    /// The account signed out and its files went (`TabCardSnapshots.signedOut`): nothing of
    /// it is held, so the same account signing in again never tells a Mac it has those blobs.
    public func signedOut() {
        heldAccount = nil
        held = [:]
        warmed = []
        arriving = [:]
        entries = [:]
        screenWaiters = [:]
    }

    public func entry(_ key: TabSnapshotKey) -> MacCardEntry {
        if let entry = entries[key] { return entry }
        let entry = MacCardEntry()
        entries[key] = entry
        return entry
    }

    /// Hands `use` the card's screen: now when it is read, else once, when the disk or the Mac
    /// brings it. A terminal card copies the screen into its own model when it is built, which on
    /// a cold launch is before the disk read (`warm`) is done: without this it never saw the screen
    /// and stayed the labeled placeholder (Leo, 2026-11-22: "so many blank previews").
    public func whenScreen(_ key: TabSnapshotKey, _ use: @escaping @MainActor (String) -> Void) {
        guard account() == key.accountID else { return }
        if let screen = entries[key]?.screen, !screen.isEmpty {
            screenWaiters[key] = nil
            use(screen)
        } else {
            screenWaiters[key] = use
        }
    }

    /// The blobs of `macID` on disk. From memory: empty until `warm(macID:)` has read the
    /// folder, which only costs the Mac sending what the phone had.
    public func heldBlobs(macID: String) -> [String] {
        guard account() != nil else { return [] }
        return Array(held[macID] ?? [])
    }

    /// Reads what the disk holds of `macID` (once per launch), off the main thread: its rows,
    /// then the favicon and screen of every card. Called when a Mac's workspaces are listed,
    /// so the cards are filled before the grid opens and before the link is up.
    @discardableResult
    public func warm(macID: String) -> Task<Void, Never>? {
        guard let account = account(), !macID.isEmpty, warmed.insert(macID).inserted else { return nil }
        let store = store
        // task-owner: this store; one read per Mac and launch.
        return Task { [weak self] in
            let disk = await Task.detached(priority: .userInitiated) { store.macDisk(accountID: account, macID: macID) }.value
            await self?.restored(disk, accountID: account, macID: macID)?.value
        }
    }

    private func restored(_ disk: MacCardDisk, accountID: String, macID: String) -> Task<Void, Never>? {
        loads += 1
        guard account() == accountID else { return nil }
        held[macID, default: []].formUnion(disk.names)
        // The link was first: its rows stand, and the file's are of an epoch it replaced. A picture
        // the file names that the link's row does not still stands for the same tab (`keeping`).
        let linkFirst = epochs[macID] != nil
        let sameEpoch = !linkFirst || epochs[macID] == disk.epoch
        if !linkFirst { epochs[macID] = disk.epoch }
        var keys: [TabSnapshotKey] = []
        for (tabID, info) in disk.cards {
            let key = TabSnapshotKey(accountID: accountID, macID: macID, tabID: tabID)
            guard !linkFirst || entries[key]?.info != nil else { continue }
            let entry = entry(key)
            // Rows the link sent meanwhile are newer than the file.
            entry.info = entry.info.map { Self.keeping($0, over: info, sameEpoch: sameEpoch) } ?? info
            keys.append(key)
        }
        // Thumbnails come from disk through the picture cache, which bounds what is decoded
        // and keeps the phone's own capture when that is newer.
        let pictured = keys.filter { key in
            guard let entry = entries[key], let hash = entry.info?.thumbHash, entry.shownThumb == nil else { return false }
            entry.shownThumb = hash
            return true
        }
        snapshots.warm(pictured)
        return fill(keys, macID: macID)
    }

    /// The Mac's tabs in its order (a manifest or a delta). A tab it no longer lists loses its
    /// row; its blobs go when the feed says no row names them (`remove`).
    ///
    /// `epoch` names the Mac's run that handed out the tab ids (empty: not said). A new epoch
    /// starts when the Mac's daemon restarts, which hands the same ids to other tabs, and also
    /// on a plain reconnect to the same daemon, where every id still names its tab. The epoch
    /// alone cannot tell the two apart, so under a new epoch a kept card stays only when its
    /// new row is still the tab it was (`sameTab`); any other card kept by that id goes first,
    /// the phone's own picture of it included, so no card shows another tab's picture. Blobs
    /// stay: they are named by content, and the new rows may name them.
    public func cards(_ cards: [(tabID: String, info: MacCardInfo)], epoch: String = "", macID: String) {
        guard let account = account(), !macID.isEmpty else { return }
        if !epoch.isEmpty {
            if let kept = epochs[macID], kept != epoch {
                void(macID: macID, except: Dictionary(cards.map { ($0.tabID, $0.info) }, uniquingKeysWith: { _, last in last }))
            }
            epochs[macID] = epoch
        }
        let listed = Set(cards.map(\.tabID))
        for key in entries.keys where key.macID == macID && !listed.contains(key.tabID) { entries[key] = nil }
        // A card the Mac no longer lists never gets its first screen: its waiter goes with it.
        for key in screenWaiters.keys where key.macID == macID && !listed.contains(key.tabID) { screenWaiters[key] = nil }
        var keys: [TabSnapshotKey] = []
        var merged: [String: MacCardInfo] = [:]
        for card in cards {
            let key = TabSnapshotKey(accountID: account, macID: macID, tabID: card.tabID)
            let entry = entry(key)
            // Past a row in memory, a row still on disk that has not been read yet is kept too (below).
            let info = Self.keeping(card.info, over: entry.info)
            entry.info = info
            merged[card.tabID] = info
            keys.append(key)
        }
        fill(keys, macID: macID)
        let store = store
        let rows = merged
        let kept = epochs[macID] ?? ""
        Task.detached(priority: .utility) {
            // The rows the file holds, when this launch has not read them: its pictures stay named.
            let disk = store.macCards(accountID: account, macID: macID)
            let sameEpoch = kept.isEmpty || store.macEpoch(accountID: account, macID: macID) == kept
            var out = rows
            for (tabID, row) in rows { out[tabID] = Self.keeping(row, over: disk[tabID], sameEpoch: sameEpoch) }
            store.putMacCards(out, accountID: account, macID: macID)
            store.putMacEpoch(kept, accountID: account, macID: macID)
        }
    }

    /// A row under a new epoch is the tab the kept row was: the same kind, and the same title
    /// or a blob in common (a page keeps its favicon while its title changes).
    nonisolated static func sameTab(_ kept: MacCardInfo, _ now: MacCardInfo) -> Bool {
        kept.kind == now.kind && (kept.title == now.title || !Set(kept.hashes).isDisjoint(with: now.hashes))
    }

    /// `now`, the Mac's newest row of a tab, with every picture of `kept` (the row it replaces) that
    /// `now` no longer names: a tab the Mac hibernated, or whose capture it has not redone, sends a
    /// row with no thumbnail, favicon or screen, and the card keeps what it showed until a newer one
    /// replaces it (Leo, 2026-11-24: "too many empty previews in the safari grid"). `sameEpoch` or
    /// `sameTab` says `kept` is this tab's row, not another tab's under a reused id.
    nonisolated static func keeping(_ now: MacCardInfo, over kept: MacCardInfo?, sameEpoch: Bool = true) -> MacCardInfo {
        guard let kept, kept.kind == now.kind, sameEpoch || sameTab(kept, now) else { return now }
        var merged = now
        if merged.faviconHash == nil { merged.faviconHash = kept.faviconHash }
        if merged.screenHash == nil, kept.screenHash != nil {
            merged.screenHash = kept.screenHash
            merged.screenColumns = kept.screenColumns
            merged.screenRows = kept.screenRows
        }
        if merged.thumbHash == nil, kept.thumbHash != nil {
            merged.thumbHash = kept.thumbHash
            // The picture is as old as it was: the phone's own newer capture still wins over it.
            merged.capturedAtMs = kept.capturedAtMs
        }
        return merged
    }

    /// Every card of `macID` whose row in `rows` is not the tab it was forgets what it showed,
    /// in place (its views observe the entry).
    private func void(macID: String, except rows: [String: MacCardInfo]) {
        for (key, entry) in entries where key.macID == macID {
            if let kept = entry.info, let now = rows[key.tabID], Self.sameTab(kept, now) { continue }
            entry.info = nil
            entry.favicon = nil
            entry.screen = nil
            entry.shownFavicon = nil
            entry.shownScreen = nil
            entry.shownThumb = nil
            snapshots.remove(key)
        }
    }

    /// Bytes that hash to `hash`: held from now on, written off the main thread.
    public func save(_ bytes: Data, hash: String, macID: String) {
        guard let account = account(), TabSnapshotStore.isHash(hash), !macID.isEmpty else { return }
        held[macID, default: []].insert(hash)
        arriving[hash] = bytes
        let store = store
        Task.detached(priority: .utility) { [weak self] in
            store.putMacBlob(bytes, hash: hash, accountID: account, macID: macID)
            await self?.written(hash, bytes)
        }
    }

    private func written(_ hash: String, _ bytes: Data) {
        // A cheap identity check: equal hashes are equal bytes.
        if arriving[hash]?.count == bytes.count { arriving[hash] = nil }
    }

    /// A blob of these cards is held: they draw it.
    @discardableResult
    public func blobArrived(hash: String, tabIDs: [String], macID: String) -> Task<Void, Never>? {
        guard let account = account() else { return nil }
        return fill(tabIDs.map { TabSnapshotKey(accountID: account, macID: macID, tabID: $0) }, macID: macID)
    }

    /// Blobs no row names any more.
    public func remove(blobs asked: [String], macID: String) {
        guard let account = account(), !asked.isEmpty else { return }
        // A picture a card still shows (its row dropped it, `keeping`) stays on disk for the next launch.
        let named = Set(entries.filter { $0.key.macID == macID }.flatMap { $0.value.info?.hashes ?? [] })
        let blobs = asked.filter { !named.contains($0) }
        guard !blobs.isEmpty else { return }
        held[macID]?.subtract(blobs)
        for hash in blobs { arriving[hash] = nil }
        let store = store
        Task.detached(priority: .utility) { store.removeMacBlobs(blobs, accountID: account, macID: macID) }
    }

    private struct Part: Sendable {
        enum Slot: Sendable { case favicon, screen, thumb }
        let key: TabSnapshotKey
        let slot: Slot
        let hash: String
        let capturedAtMs: Int64
        var bytes: Data?
    }

    private struct Loaded: @unchecked Sendable {
        let part: Part
        var image: UIImage?
        var text: String?
    }

    /// Shows, for each of `keys`, the held blobs its row names and its card does not show yet.
    /// Bytes are read and pictures decoded off the main thread; a blob not held yet changes
    /// nothing (what the card showed stays).
    @discardableResult
    private func fill(_ keys: [TabSnapshotKey], macID: String) -> Task<Void, Never>? {
        let held = held[macID] ?? []
        var wanted: [Part] = []
        for key in keys {
            guard let entry = entries[key], let info = entry.info else { continue }
            func want(_ hash: String?, shown: String?, _ slot: Part.Slot) {
                guard let hash, hash != shown, held.contains(hash) else { return }
                wanted.append(Part(key: key, slot: slot, hash: hash, capturedAtMs: info.capturedAtMs, bytes: arriving[hash]))
            }
            // A row that names no favicon or screen (a tab the Mac hibernated) leaves what the card
            // shows: it goes only when a newer one replaces it, or its tab does (`void`).
            want(info.faviconHash, shown: entry.shownFavicon, .favicon)
            want(info.screenHash, shown: entry.shownScreen, .screen)
            want(info.thumbHash, shown: entry.shownThumb, .thumb)
        }
        guard !wanted.isEmpty else { return nil }
        let parts = wanted
        let store = store
        // task-owner: this store; ends when the parts are shown.
        return Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) {
                parts.map { part -> Loaded in
                    let bytes = part.bytes ?? store.macBlob(part.hash, accountID: part.key.accountID, macID: part.key.macID)
                    switch part.slot {
                    case .screen: return Loaded(part: part, text: bytes.map { String(decoding: $0, as: UTF8.self) })
                    case .favicon: return Loaded(part: part, image: bytes.flatMap { UIImage(data: $0) })
                    // A Mac thumbnail that is a placeholder (`CardPictureGate`) is never shown.
                    case .thumb: return Loaded(part: part, image: bytes.flatMap { UIImage(data: $0) }
                        .flatMap { CardPictureGate.isPlaceholder($0) ? nil : $0 }?.preparingForDisplay())
                    }
                }
            }.value
            self?.show(loaded)
        }
    }

    private func show(_ loaded: [Loaded]) {
        for item in loaded {
            let part = item.part
            // The row moved on while the bytes were read: the newer fill shows its own.
            guard let entry = entries[part.key], let info = entry.info else { continue }
            switch part.slot {
            case .favicon:
                guard info.faviconHash == part.hash, let image = item.image else { continue }
                entry.favicon = image
                entry.shownFavicon = part.hash
            case .screen:
                guard info.screenHash == part.hash, let text = item.text else { continue }
                entry.screen = text
                entry.shownScreen = part.hash
                if !text.isEmpty { screenWaiters.removeValue(forKey: part.key)?(text) }
            case .thumb:
                guard info.thumbHash == part.hash, let image = item.image else { continue }
                entry.shownThumb = part.hash
                snapshots.show(macPicture: image, capturedAtMs: part.capturedAtMs, for: part.key)
            }
        }
    }
}
#endif
