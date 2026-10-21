import AppKit
@testable import CmuxNextApp
@testable import CmuxNextRemoteView
@testable import CmuxNextRemoteViewSessions
import CmuxVNC
import Foundation
import Testing

/// VNC compatibility hosts in the remote view pane (remote-desktop.md 12).
struct RemoteViewVNCRecordTests {
    @Test func vncRecordRoundTrips() throws {
        let record = try #require(RemoteViewTabRecord(host: "cmux10s-mac-mini", mode: .control, vncPort: 5901))
        let parsed = try #require(RemoteViewTabRecord(url: record.url))
        #expect(parsed == record)
        #expect(record.url.absoluteString.contains("via=vnc&port=5901"))
    }

    @Test func vncWithoutPortDefaultsTo5900() throws {
        let record = try #require(RemoteViewTabRecord(url: URL(string: "cmux://remote-view?host=mac.local&via=vnc")))
        #expect(record.vncPort == 5900)
    }

    @Test func rdRecordsAreUnchanged() throws {
        let record = try #require(RemoteViewTabRecord(host: "mock"))
        #expect(record.vncPort == nil)
        #expect(!record.url.absoluteString.contains("via"))
    }

    @Test(arguments: [
        "cmux://remote-view?host=a&via=vnc&port=0",
        "cmux://remote-view?host=a&via=vnc&port=70000",
        "cmux://remote-view?host=a&via=vnc&port=-1",
        "cmux://remote-view?host=a&via=ssh",
        "cmux://remote-view?host=a&port=5900",
        "cmux://remote-view?host=a&via=vnc&via=vnc",
    ])
    func rejectsBadVNCFields(_ raw: String) {
        #expect(RemoteViewTabRecord(url: URL(string: raw)) == nil)
    }
}

struct RemoteViewVNCPolicyTests {
    let policy = RemoteViewTabPolicy()

    @Test(arguments: ["mock", "127.0.0.1", "100.70.231.80", "100.127.0.1", "10.0.0.5", "172.20.21.138", "192.168.1.2",
                      "mini.tail137216.ts.net", "studio.local", "cmux10s-mac-mini"])
    func privateHostsConnect(_ host: String) throws {
        let record = try #require(RemoteViewTabRecord(host: host, vncPort: 5900))
        #expect(policy.decide(record: record, source: .person, paneAvailable: true) == .connect(record))
    }

    @Test(arguments: ["8.8.8.8", "100.128.0.1", "172.32.0.1", "example.com", "203.0.113.4", "134744072", "0x08080808", "8.8.2056"])
    func publicHostsAreRefused(_ host: String) throws {
        let record = try #require(RemoteViewTabRecord(host: host, vncPort: 5900))
        #expect(policy.decide(record: record, source: .person, paneAvailable: true) == .unavailable(.notPrivateNetwork(host: host)))
    }

    @Test func rdStaysLoopbackOnly() throws {
        let record = try #require(RemoteViewTabRecord(host: "10.0.0.5"))
        #expect(policy.decide(record: record, source: .person, paneAvailable: true) == .unavailable(.notLoopback(host: "10.0.0.5")))
    }

    @Test func unconfirmedVNCAsksAndStartsInViewMode() throws {
        let record = try #require(RemoteViewTabRecord(host: "studio.local", mode: .control, vncPort: 5900))
        guard case let .confirm(asked) = policy.decide(record: record, source: .unconfirmed, paneAvailable: true) else {
            Issue.record("expected confirm")
            return
        }
        #expect(asked.mode == .view && asked.vncPort == 5900)
    }

    @Test func remoteTreeVNCRecordsNeverOpen() throws {
        let record = try #require(RemoteViewTabRecord(host: "mock", vncPort: 5900))
        #expect(policy.decide(record: record, source: .remoteTree, paneAvailable: true) == .unavailable(.remoteRecord))
    }
}

struct RemoteViewFitGeometryTests {
    @Test func fitScalesDownAndCenters() {
        let geometry = RemoteViewGeometry(framePixels: CGSize(width: 2000, height: 1000), bounds: CGRect(x: 0, y: 0, width: 400, height: 400),
                                          backingScale: 2, scaling: .fit)
        #expect(geometry.imageRect == CGRect(x: 0, y: 100, width: 400, height: 200))
        let pixel = geometry.streamPixel(at: CGPoint(x: 200, y: 200))
        #expect(pixel?.x == 1000 && pixel?.y == 500)
        #expect(geometry.streamPixel(at: CGPoint(x: 200, y: 50)) == nil)
        let point = geometry.panePoint(forStreamPixel: 1000, 500)
        #expect(point == CGPoint(x: 200, y: 200))
    }

    @Test func fitScalesUp() {
        let geometry = RemoteViewGeometry(framePixels: CGSize(width: 100, height: 100), bounds: CGRect(x: 0, y: 0, width: 300, height: 200),
                                          backingScale: 2, scaling: .fit)
        #expect(geometry.imageRect == CGRect(x: 50, y: 0, width: 200, height: 200))
        #expect(geometry.clampedStreamPixel(at: CGPoint(x: 249, y: 199)) == (99, 99))
    }

    @Test func nativeIsUnchanged() {
        let geometry = RemoteViewGeometry(framePixels: CGSize(width: 800, height: 600), bounds: CGRect(x: 0, y: 0, width: 400, height: 300),
                                          backingScale: 2)
        #expect(geometry.imageRect == CGRect(x: 0, y: 0, width: 400, height: 300))
    }
}

struct RemoteVNCMappingTests {
    @Test func failuresMapToPaneEnds() {
        #expect(RemoteVNCSource.end(for: nil, hadCredentials: false) == .stoppedByViewer)
        #expect(RemoteVNCSource.end(for: .credentialsRequired, hadCredentials: false) == .signInRequired(rejected: false))
        #expect(RemoteVNCSource.end(for: .passwordRequired, hadCredentials: false) == .signInRequired(rejected: false))
        #expect(RemoteVNCSource.end(for: .authenticationFailed("no"), hadCredentials: true) == .signInRequired(rejected: true))
        #expect(RemoteVNCSource.end(for: .transport("refused"), hadCredentials: true) == .connectionLost)
        #expect(RemoteVNCSource.end(for: .connectionClosed, hadCredentials: false) == .connectionLost)
    }

    @Test func scrollAccumulatesToWheelClicks() {
        var scroll = RemoteVNCScroll()
        #expect(scroll.add(dx: 0, dy: 50, precise: false) == (0, 0))
        #expect(scroll.add(dx: 0, dy: 60, precise: false) == (0, 1))
        #expect(scroll.add(dx: -250, dy: 0, precise: false) == (-2, 0))
        #expect(scroll.add(dx: 0, dy: -1500, precise: true) == (0, -1))
    }
}
