#if os(iOS)
import CmuxMobileDesign
import CmuxMobileTransport
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "appearance")

/// Keeps the phone looking like its Mac (PROTOCOL.md "Appearance",
/// `appearance-v1`): `get-appearance` when the `daemon` channel binds and on
/// each `appearance-changed`, the snapshot stored per Mac, the background
/// image fetched once by hash over `appearance-asset` (length and SHA-256
/// checked before it is kept), then the look applied to
/// ``CmuxMobileAppearance``. Offline or on Cloud nothing here runs: the phone
/// draws the last stored snapshot, derived locally.
@MainActor
public final class AppearanceSync {
    /// What a fetch needs from one Mac's connection.
    public struct Connection {
        public var macID: String
        /// `get-appearance` (the daemon reply line).
        public var request: @Sendable () async throws -> Data
        /// Opens `appearance-asset {sha256}`.
        public var openAsset: @Sendable (_ sha256: String) async throws -> any LinkChannel

        public init(macID: String, request: @escaping @Sendable () async throws -> Data,
                    openAsset: @escaping @Sendable (_ sha256: String) async throws -> any LinkChannel) {
            self.macID = macID
            self.request = request
            self.openAsset = openAsset
        }
    }

    public static let shared = AppearanceSync(appearance: .shared)

    private let appearance: CmuxMobileAppearance
    private var disk: CmuxMobileAppearanceDisk { appearance.disk }
    /// One fetch per Mac at a time; a change during it fetches once more after.
    private var running: [String: Task<Void, Never>] = [:]
    private var again: Set<String> = []
    /// Macs whose next stored snapshot makes them the matched Mac.
    private var connecting: Set<String> = []
    /// Images being fetched (one fetch per hash, whichever Mac asked).
    private var fetching: Set<String> = []
    /// Called after a snapshot was applied (tests, the live-change timing).
    var onApplied: (@MainActor (CmuxMobileAppearanceSnapshot) -> Void)?

    public init(appearance: CmuxMobileAppearance) {
        self.appearance = appearance
    }

    /// The Mac changed its look (`appearance-changed`), or its `daemon`
    /// channel bound (`connected`: it becomes the Mac "Match my Mac" follows,
    /// the one most recently connected): read it again.
    public func changed(_ connection: Connection, connected: Bool = false) {
        let macID = connection.macID
        guard !macID.isEmpty else { return }
        if connected { connecting.insert(macID) }
        if running[macID] != nil {
            again.insert(macID)
            return
        }
        running[macID] = Task { [weak self] in
            await self?.fetch(connection)
            guard let self else { return }
            running[macID] = nil
            if again.remove(macID) != nil { changed(connection) }
        }
    }

    /// Waits for `macID`'s fetch in flight (tests).
    func settle(_ macID: String) async {
        while let task = running[macID] { await task.value }
    }

    private func fetch(_ connection: Connection) async {
        let reply: Data
        do {
            reply = try await connection.request()
        } catch {
            // An older Mac (no `appearance-v1`) answers unknown command: the stored look stays.
            log.info("get-appearance failed: \(String(describing: error), privacy: .public)")
            return
        }
        guard let snapshot = CmuxMobileAppearanceSnapshot.parse(reply: reply) else {
            log.info("get-appearance: no snapshot in the reply")
            return
        }
        apply(snapshot, macID: connection.macID)
        // The image after the colors: they never wait on it.
        if let background = snapshot.background, background.hasValidHash,
           disk.assetURL(sha256: background.sha256) == nil, !fetching.contains(background.sha256) {
            fetching.insert(background.sha256)
            defer { fetching.remove(background.sha256) }
            if await Self.download(background, open: connection.openAsset, disk: disk) != nil {
                apply(snapshot, macID: connection.macID)
            }
        }
    }

    /// Stores `snapshot` as `macID`'s and redraws when it is the look the phone matches.
    func apply(_ snapshot: CmuxMobileAppearanceSnapshot, macID: String) {
        disk.store(snapshot, macID: macID, makeCurrent: connecting.remove(macID) != nil || disk.lastMacID == nil)
        appearance.macSnapshotChanged(macID: macID)
        onApplied?(snapshot)
    }

    /// Reads `appearance-asset`: a JSON header `{"bytes", "mime"}`, the bytes
    /// in data frames, then the close. Keeps the file only when its length
    /// and SHA-256 match the snapshot's. At most 32 MiB (the Mac's cap).
    static func download(_ background: CmuxMobileAppearanceSnapshot.Background,
                         open: @Sendable (String) async throws -> any LinkChannel,
                         disk: CmuxMobileAppearanceDisk) async -> URL? {
        let cap = 32 << 20
        do {
            let channel = try await open(background.sha256)
            guard let header = try await channel.receive(), header.count <= 1024,
                  let object = try? JSONSerialization.jsonObject(with: header) as? [String: Any],
                  let bytes = object["bytes"] as? Int, bytes > 0, bytes <= cap,
                  background.bytes == 0 || bytes == background.bytes else {
                await channel.close(code: "cancelled", reason: "bad appearance-asset header")
                return nil
            }
            var data = Data()
            data.reserveCapacity(bytes)
            while let frame = try await channel.receive() {
                data.append(frame)
                if data.count > bytes {
                    await channel.close(code: "cancelled", reason: "appearance-asset longer than announced")
                    return nil
                }
            }
            guard let url = disk.storeAsset(data, sha256: background.sha256, bytes: bytes) else {
                log.error("appearance-asset \(background.sha256, privacy: .public): length or hash mismatch, dropped")
                return nil
            }
            return url
        } catch {
            log.info("appearance-asset failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
#endif
