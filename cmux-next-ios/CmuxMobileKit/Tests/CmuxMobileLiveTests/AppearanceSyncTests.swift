#if os(iOS)
import CmuxMobileDesign
import CmuxMobileTransport
import Foundation
import Observation
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileLive

/// PROTOCOL.md "Appearance" on the phone: the snapshot parses (lenient), is
/// stored per Mac, its image is fetched once by hash and kept only when its
/// length and hash match (at most 8, least recently used dropped), offline
/// the phone draws the last stored snapshot, and a live `appearance-changed`
/// reaches the screen in a measured time.
@MainActor
@Suite(.serialized) struct AppearanceSyncTests {
    // MARK: - Fixtures

    private func scratch() -> (CmuxMobileAppearanceDisk, CmuxMobileAppearance) {
        let name = "AppearanceSyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        let disk = CmuxMobileAppearanceDisk(root: root, defaults: defaults)
        return (disk, CmuxMobileAppearance(accentTheme: CmuxMobileAccentTheme(defaults: defaults), disk: disk))
    }

    private nonisolated static let nordJSON = #"""
    {"background":"#2E3440","foreground":"#D8DEE9","palette":["#3B4252","#BF616A","#A3BE8C","#EBCB8B","#81A1C1","#B48EAD","#88C0D0","#E5E9F0","#4C566A","#BF616A","#A3BE8C","#EBCB8B","#81A1C1","#B48EAD","#8FBCBB","#ECEFF4"],"cursor":"#ECEFF4","background_opacity":1,"background_blur":0}
    """#

    private nonisolated static func reply(revision: Int, background: String = "null", wrapped: Bool = true, accent: String = "blue") -> Data {
        let appearance = #"""
        {"revision":\#(revision),"theme":{"dark":{"name":"Nord","input":\#(nordJSON)},"light":{"name":"Nord","input":\#(nordJSON)},"follows_system":true},
         "accent":"\#(accent)","chrome_style":"two-tone","hue":0.5,"saturation":1.0,"glass_transparency":0.5,"sidebar_surface":"glass",
         "terminal":{"font_family":"JetBrains Mono","font_size":13},
         "chat":{"sent":"#88C0D0","sent_text":"#2E3440"},
         "groups":{"palette":["blue","red"],"gradient":"aurora"},"background":\#(background)}
        """#
        return Data((wrapped ? #"{"ok":true,"data":{"appearance":\#(appearance)}}"# : appearance).utf8)
    }

    private nonisolated static let picture = Data((0..<4096).map { UInt8($0 % 251) })
    private nonisolated static var pictureHash: String { CmuxMobileAppearanceDisk.sha256(picture) }
    private nonisolated static var backgroundJSON: String {
        #"{"sha256":"\#(pictureHash)","bytes":\#(picture.count),"width":1600,"height":1000,"luminance":0.4,"opacity":0.8,"blur":10}"#
    }

    /// `appearance-asset`: a header, the bytes in 1 KiB frames, then the close.
    final class AssetChannel: LinkChannel, @unchecked Sendable {
        let id: UInt32 = 9
        private let lock = NSLock()
        private var frames: [Data]

        init(header: Data, body: Data, frame: Int = 1024) {
            var frames = [header]
            var offset = 0
            while offset < body.count {
                frames.append(body.subdata(in: offset..<min(offset + frame, body.count)))
                offset += frame
            }
            self.frames = frames
        }

        func send(_ data: Data) async throws {}
        func receive() async throws -> Data? { lock.withLock { frames.isEmpty ? nil : frames.removeFirst() } }
        func close(code: String, reason: String) async { lock.withLock { frames = [] } }
    }

    final class Stamp: @unchecked Sendable {
        private let lock = NSLock()
        private var at: ContinuousClock.Instant?
        func mark() { lock.withLock { at = at ?? .now } }
        var marked: Bool { lock.withLock { at != nil } }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    private func connection(macID: String, reply: @escaping @Sendable () -> Data, opens: Counter, body: Data = picture) -> AppearanceSync.Connection {
        AppearanceSync.Connection(macID: macID, request: { reply() }, openAsset: { _ in
            opens.bump()
            let header = Data(#"{"bytes":\#(body.count),"mime":"image/jpeg"}"#.utf8)
            return AssetChannel(header: header, body: body)
        })
    }

    // MARK: - Parsing

    @Test func parsesTheReplyLeniently() throws {
        let wrapped = try #require(CmuxMobileAppearanceSnapshot.parse(reply: Self.reply(revision: 42)))
        #expect(wrapped.revision == 42)
        #expect(wrapped.theme?.dark?.name == "Nord")
        #expect(wrapped.theme?.dark?.input.palette.count == 16)
        #expect(wrapped.theme?.followsSystem == true)
        #expect(wrapped.accent == "blue")
        #expect(wrapped.chromeStyle == "two-tone")
        #expect(wrapped.glassTransparency == 0.5)
        #expect(wrapped.terminal?.fontFamily == "JetBrains Mono")
        #expect(wrapped.chat?.sent == "#88C0D0")
        #expect(wrapped.chat?.sentText == "#2E3440")
        // A palette given as a list (not the setting's one name) reads as unset, not as a failed snapshot.
        #expect(wrapped.groups?.palette == nil)
        #expect(wrapped.groups?.gradient == "aurora")
        #expect(wrapped.background == nil)
        let bare = try #require(CmuxMobileAppearanceSnapshot.parse(reply: Self.reply(revision: 3, wrapped: false)))
        #expect(bare.revision == 3)
        // No snapshot in an error or an older Mac's reply.
        #expect(CmuxMobileAppearanceSnapshot.parse(reply: Data(#"{"ok":false,"error":"unknown command"}"#.utf8)) == nil)
        // Stored and read back unchanged.
        #expect(CmuxMobileAppearanceSnapshot.decode(wrapped.encoded()) == wrapped)
    }

    @Test func derivesWithTheMacsCode() throws {
        let snapshot = try #require(CmuxMobileAppearanceSnapshot.parse(reply: Self.reply(revision: 1)))
        let look = try #require(CmuxMobileAppearanceResolver.resolve(snapshot, backgroundURL: nil))
        // Nord's background is the page; the terminal takes the theme's colors and font.
        #expect(look.palette[.bg].dark.hex == "#2E3440")
        #expect(look.terminal.dark.background.hex == "#2E3440")
        #expect(look.terminal.dark.palette.count == 16)
        #expect(look.terminal.dark.palette[4].hex == "#81A1C1")
        #expect(look.terminal.fontFamily == "JetBrains Mono")
        // The Mac's bubble colors; its blue accent is not the neutral one.
        #expect(look.palette[.bubble].dark.hex == "#88C0D0")
        #expect(look.palette[.onBubble].dark.hex == "#2E3440")
        #expect(look.palette[.accent] != look.palette[.label])
        // Two-tone: the sidebar has a shade of its own.
        #expect(look.palette[.sidebarShade].dark.alpha > 0)
        #expect(look.colorScheme == nil)
        #expect(look.backdrop == nil)
    }

    // MARK: - Storage

    @Test func storesPerMacAndCachesImagesByHash() throws {
        let (disk, _) = scratch()
        let snapshot = try #require(CmuxMobileAppearanceSnapshot.parse(reply: Self.reply(revision: 5)))
        #expect(disk.store(snapshot, macID: "mac-a"))
        #expect(!disk.store(snapshot, macID: "mac-a"))
        #expect(disk.snapshot(macID: "mac-a") == snapshot)
        #expect(disk.snapshot(macID: "mac-b") == nil)
        #expect(disk.lastMacID == "mac-a")
        // A path-unsafe id is stored under its hash, never as a path.
        disk.store(snapshot, macID: "../evil/mac", makeCurrent: false)
        #expect(disk.snapshot(macID: "../evil/mac") == snapshot)
        #expect(disk.lastMacID == "mac-a")

        // Wrong hash or length: not kept.
        #expect(disk.storeAsset(Self.picture, sha256: String(repeating: "a", count: 64)) == nil)
        #expect(disk.storeAsset(Self.picture, sha256: Self.pictureHash, bytes: Self.picture.count + 1) == nil)
        #expect(disk.storeAsset(Self.picture, sha256: Self.pictureHash, bytes: Self.picture.count) != nil)
        #expect(disk.assetURL(sha256: Self.pictureHash) != nil)

        // At most eight, least recently used dropped.
        var hashes: [String] = [Self.pictureHash]
        for index in 0..<8 {
            let data = Data("image \(index)".utf8)
            let hash = CmuxMobileAppearanceDisk.sha256(data)
            #expect(disk.storeAsset(data, sha256: hash) != nil)
            hashes.append(hash)
            if index == 3 { _ = disk.assetURL(sha256: Self.pictureHash) }  // used again: stays
        }
        let kept = disk.assetHashes()
        #expect(kept.count == CmuxMobileAppearanceDisk.assetLimit)
        #expect(kept.contains(Self.pictureHash))
        #expect(!kept.contains(hashes[1]))
        #expect(kept.first == hashes.last)
    }

    @Test func offlineDrawsTheLastStoredSnapshot() throws {
        let (disk, appearance) = scratch()
        // Never connected: the neutral look.
        #expect(appearance.storedLook().1 == .neutral)
        appearance.loadAtLaunch()
        #expect(!appearance.isThemed)
        #expect(appearance.token(.bg).dark.hex == "#000000")
        // A Mac's snapshot was stored on an earlier connection; now there is no link.
        let snapshot = try #require(CmuxMobileAppearanceSnapshot.parse(reply: Self.reply(revision: 9)))
        disk.store(snapshot, macID: "mac-a")
        let relaunched = CmuxMobileAppearance(accentTheme: CmuxMobileAccentTheme(defaults: UserDefaults(suiteName: UUID().uuidString)!), disk: disk)
        relaunched.loadAtLaunch()
        #expect(relaunched.isThemed)
        #expect(relaunched.source == .mac("mac-a"))
        #expect(relaunched.token(.bg).dark.hex == "#2E3440")
        #expect(relaunched.terminal.dark.background.hex == "#2E3440")
    }

    // MARK: - Sync

    @Test func fetchesTheImageOnceByHash() async throws {
        let (disk, appearance) = scratch()
        let sync = AppearanceSync(appearance: appearance)
        let opens = Counter()
        let background = Self.backgroundJSON
        let conn = connection(macID: "mac-a", reply: { Self.reply(revision: 2, background: background) }, opens: opens)
        sync.changed(conn, connected: true)
        await sync.settle("mac-a")
        #expect(opens.count == 1)
        #expect(disk.assetURL(sha256: Self.pictureHash) != nil)
        #expect(appearance.backdrop?.sha256 == Self.pictureHash)
        #expect(appearance.backdrop?.opacity == 0.8)
        // Over a backdrop the page is clear: the backdrop draws it once.
        #expect(appearance.token(.bg).dark.alpha == 0)
        // Another change with the same image: never fetched again.
        sync.changed(conn)
        await sync.settle("mac-a")
        #expect(opens.count == 1)
    }

    @Test func dropsAnImageWhoseHashDoesNotMatch() async throws {
        let (disk, appearance) = scratch()
        let sync = AppearanceSync(appearance: appearance)
        let opens = Counter()
        let background = Self.backgroundJSON
        var tampered = Self.picture
        tampered[0] ^= 0xFF
        let conn = connection(macID: "mac-a", reply: { Self.reply(revision: 2, background: background) }, opens: opens, body: tampered)
        sync.changed(conn, connected: true)
        await sync.settle("mac-a")
        #expect(opens.count == 1)
        #expect(disk.assetURL(sha256: Self.pictureHash) == nil)
        // The colors still apply; no backdrop without its image.
        #expect(appearance.isThemed)
        #expect(appearance.backdrop == nil)
    }

    @Test func anotherMacsChangeDoesNotReplaceTheMatchedLook() async throws {
        let (disk, appearance) = scratch()
        let sync = AppearanceSync(appearance: appearance)
        let opens = Counter()
        sync.changed(connection(macID: "mac-a", reply: { Self.reply(revision: 1, accent: "blue") }, opens: opens), connected: true)
        await sync.settle("mac-a")
        let blue = appearance.token(.accent)
        // mac-b was connected earlier and only changes its look now: stored, not shown.
        sync.changed(connection(macID: "mac-b", reply: { Self.reply(revision: 1, accent: "red") }, opens: opens))
        await sync.settle("mac-b")
        #expect(disk.snapshot(macID: "mac-b")?.accent == "red")
        #expect(appearance.token(.accent) == blue)
        #expect(appearance.source == .mac("mac-a"))
    }

    // MARK: - Live change

    /// An `appearance-changed` on the daemon stream, through `get-appearance`
    /// and the derivation, until the store publishes and a frame that reads
    /// it is committed. Prints the milliseconds.
    @Test func liveChangeReachesTheScreen() async throws {
        let (_, appearance) = scratch()
        let sync = AppearanceSync(appearance: appearance)
        let opens = Counter()
        let revision = Counter()
        let conn = connection(macID: "mac-a", reply: { revision.bump(); return Self.reply(revision: revision.count, accent: revision.count.isMultiple(of: 2) ? "red" : "blue") }, opens: opens)
        sync.changed(conn, connected: true)
        await sync.settle("mac-a")

        // A window showing a view that reads a token, as every screen does.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIHostingController(rootView: TokenProbe(appearance: appearance))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()

        var samples: [Double] = []
        for _ in 0..<5 {
            let started = ContinuousClock.now
            let published = Stamp()
            withObservationTracking { _ = appearance.resolved } onChange: { published.mark() }
            // The daemon's event, as WorkspaceSync hands it on.
            #expect(DaemonEvent.parse(Data(#"{"event":"appearance-changed","revision":7}"#.utf8)) == .appearanceChanged(revision: 7))
            sync.changed(conn)
            await sync.settle("mac-a")
            #expect(published.marked)
            // The frame: SwiftUI's update for the change, laid out and committed.
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            CATransaction.flush()
            let committed = ContinuousClock.now
            let elapsed = committed - started
            samples.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        print("APPEARANCE_LIVE_CHANGE_MS median=\(String(format: "%.2f", median)) max=\(String(format: "%.2f", sorted.last ?? 0)) samples=\(samples.map { String(format: "%.2f", $0) })")
        #expect(median < 100)
        window.isHidden = true
    }

    private struct TokenProbe: View {
        let appearance: CmuxMobileAppearance
        var body: some View {
            Rectangle().fill(appearance.token(.accent).color).frame(width: 40, height: 40)
        }
    }
}
#endif
