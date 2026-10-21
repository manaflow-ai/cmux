import CmuxMobileFeed
import CmuxMobileModel
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// Dials a fresh mock link per dial and counts dials and closes per Mac.
final class PerMacDialer: MacLinkDialer, @unchecked Sendable {
    private let lock = NSLock()
    private var dials: [String: Int] = [:]
    /// What each Mac's daemon answers (`read-screen` text, workspace keys).
    let screens: [String: String]

    init(screens: [String: String] = [:]) {
        self.screens = screens
    }

    func dialCount(_ macID: String) -> Int { lock.withLock { dials[macID] ?? 0 } }

    func dial(_ endpoint: LinkEndpoint, transport: CmuxMobileTransport.TransportKind, accessToken: String) async throws -> any MacLink {
        let mac = endpoint.macDeviceID
        lock.withLock { dials[mac, default: 0] += 1 }
        let screen = screens[mac] ?? mac
        return MockMacLink(transport: transport) { service, data in
            guard service == "daemon" else { return [] }
            return data.split(separator: 0x0A).compactMap { request -> Data? in
                guard let object = try? JSONSerialization.jsonObject(with: Data(request)) as? [String: Any],
                      let id = object["id"] as? String else { return nil }
                let line: String
                switch object["cmd"] as? String ?? "" {
                case "list-workspaces":
                    // Both Macs number their surfaces from 1: the same tab id `s1` on each.
                    line = #"{"id":"\#(id)","ok":true,"data":{"workspaces":[{"id":1,"key":"ws-\#(mac)","name":"\#(mac)","screens":[{"id":1,"active":true,"active_pane":1,"panes":[{"id":1,"active_tab":0,"tabs":[{"surface":1,"kind":"pty","title":"zsh"}]}]}]}]}}"#
                case "list-agents":
                    line = #"{"id":"\#(id)","ok":true,"data":{"agents":[]}}"#
                case "read-screen":
                    line = #"{"id":"\#(id)","ok":true,"data":{"text":"\#(screen)"}}"#
                default:
                    line = #"{"id":"\#(id)","ok":true,"data":{}}"#
                }
                return Data(line.utf8) + Data([0x0A])
            }
        }
    }
}

// The coordinator is iOS-only: these run in the iOS simulator test pass.
#if os(iOS)
/// The phone holds one link per online Mac at once (PROTOCOL.md "One link per
/// Mac"). Before, one link served the account: choosing a second Mac (opening
/// one of its workspaces) closed the first Mac's link, so its workspaces said
/// "Can't connect" and its terminals ended until it was chosen again.
@MainActor
@Suite(.serialized) struct MultiMacLinkTests {
    let host = "svc-\(UUID().uuidString.prefix(8).lowercased()).cmuxMobile.test"
    let userID = "user-\(UUID().uuidString)"

    func coordinator(store: AppStore, dialer: PerMacDialer) -> LiveCoordinator {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-mobile-multimac-\(UUID().uuidString)")
        let snapshots = LiveSnapshotStore(directory: directory)
        let saved = Date(timeIntervalSince1970: 1_000)
        snapshots.save(LiveSnapshot(
            teamID: "t1", teamName: "One",
            macs: [MacDevice(id: "m1", name: "Aziz's MacBook Pro", isOnline: true), MacDevice(id: "m2", name: "MacBook Pro", isOnline: true)],
            linkedMacID: "m1",
            workspaces: ["m1": .init(workspaces: [], savedAt: saved), "m2": .init(workspaces: [], savedAt: saved)]
        ), accountID: userID)
        snapshots.flush()
        return LiveCoordinator(
            store: store,
            api: LiveAPI(baseURL: URL(string: "https://\(host)")!, session: ServiceStub.session()) { _ in "token" },
            identity: DeviceIdentity(link: UUID().uuidString, presence: UUID().uuidString),
            userID: userID, deviceName: "iPhone", transport: .wireGuard, dialer: dialer,
            feedStore: FeedStore(items: []), snapshots: snapshots
        )
    }

    func emptyStore() -> AppStore {
        AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: .inMemory())
    }

    func settle(_ done: () -> Bool) async {
        for _ in 0..<3000 where !done() { try? await Task.sleep(for: .milliseconds(1)) }
    }

    func drain() async {
        for _ in 0..<50 { try? await Task.sleep(for: .milliseconds(2)) }
    }

    /// The user's report: two Macs online, and only the one whose workspace was
    /// opened last stays connected. Opening the second Mac's workspace must not
    /// close the first Mac's link.
    @Test func choosingTheSecondMacKeepsTheFirstLinked() async {
        let key = "cmuxMobile.live.mac.t1"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let store = emptyStore()
        let dialer = PerMacDialer()
        let live = coordinator(store: store, dialer: dialer)
        defer { live.stop() }
        await settle { store.macConnection["m1"] == .connected }
        #expect(store.macConnection["m1"] == .connected)

        live.select(macID: "m2")
        await settle { store.macConnection["m2"] == .connected }
        await drain()
        #expect(store.macConnection["m2"] == .connected)
        #expect(store.macConnection["m1"] == .connected)
        // The first Mac's link was never closed and redialed.
        #expect(dialer.dialCount("m1") == 1)
        #expect(dialer.dialCount("m2") == 1)
        // Both Macs' workspaces are live at once.
        await settle { store.macDataPhase("m1") == .live && store.macDataPhase("m2") == .live }
        #expect(store.macDataPhase("m1") == .live)
        #expect(store.macDataPhase("m2") == .live)

        // Back to the first Mac: nothing redials either.
        live.select(macID: "m1")
        await drain()
        #expect(dialer.dialCount("m1") == 1)
        #expect(dialer.dialCount("m2") == 1)
        #expect(store.macConnection["m2"] == .connected)
    }
}
#endif
