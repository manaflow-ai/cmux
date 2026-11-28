// The phone's connection contract through the real Swift binding: the same fixture Rust checks
// (rust/crates/cmux-mobile-link-ffi/tests/fixtures/connection_contract.json; map in
// cmux-next-ios/contract/README.md). A Rust change to a resolution, an action, a LinkEvent or a
// MediaState lands in the fixture with it; this suite then fails until the binding and iOS agree.

import Foundation
import Testing
import CmuxMobileLinkFFI

enum ConnectionContract {
    static func load(filePath: String = #filePath) throws -> [String: Any] {
        // Tests/CmuxMobileLinkFFILinuxTests/<file> -> cmux-next-ios
        let root = URL(fileURLWithPath: filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("rust/crates/cmux-mobile-link-ffi/tests/fixtures/connection_contract.json")
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}

/// Exhaustive: a new LinkEvent case is a compile error here before it reaches iOS.
private func name(_ event: LinkEvent) -> String {
    switch event {
    case .connecting: "Connecting"
    case .connected: "Connected"
    case .pathChanged: "PathChanged"
    case .rtt: "Rtt"
    case .media: "Media"
    case .disconnected: "Disconnected"
    case .suspect: "Suspect"
    }
}

private func name(_ media: MediaState) -> String {
    switch media {
    case .off: "Off"
    case .connecting: "Connecting"
    case .up: "Up"
    case .failed: "Failed"
    }
}

private func name(_ kind: MacReachabilityKind) -> String {
    switch kind {
    case .connected: "Connected"
    case .connecting: "Connecting"
    case .notConnected: "NotConnected"
    case .slow: "Slow"
    case .offline: "Offline"
    case .noAnswer: "NoAnswer"
    case .serviceDown: "ServiceDown"
    case .authRequired: "AuthRequired"
    case .notAllowed: "NotAllowed"
    case .phoneOffline: "PhoneOffline"
    }
}

@Suite struct ConnectionContractTests {
    @Test func everyLinkEventAndMediaVariantIsOneSwiftKnows() throws {
        let contract = try ConnectionContract.load()
        let events: [LinkEvent] = [
            .connecting(transport: .wireGuard), .connected(transport: .wireGuard, path: .direct),
            .pathChanged(path: .turn), .rtt(millis: 1), .media(state: .off),
            .disconnected(reason: ""), .suspect(silentMillis: 1),
        ]
        let media: [MediaState] = [.off, .connecting, .up(path: .direct, rttMillis: nil), .failed(reason: "", retryInMillis: 0)]
        #expect(events.map(name) == (contract["link_event_variants"] as? [String]))
        #expect(media.map(name) == (contract["media_state_variants"] as? [String]))
    }

    @Test func everyReachabilityCaseResolvesThroughTheBinding() throws {
        let contract = try ConnectionContract.load()
        let cases = try #require(contract["reachability"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        for c in cases {
            let label = c["name"] as? String ?? "?"
            let i = try #require(c["input"] as? [String: Any])
            var connection: MacLinkState?
            switch i["connection"] as? String {
            case "Connecting": connection = .connecting
            case "Connected": connection = .connected
            case "Failed": connection = .failed
            case nil: connection = nil
            case let other?: Issue.record("\(label): unknown connection \(other)")
            }
            var failure: MacLinkFailureKind?
            switch i["failure"] as? String {
            case "HostUnreachable": failure = .hostUnreachable
            case "ServiceDown": failure = .serviceDown
            case "AuthRequired": failure = .authRequired
            case "NotAllowed": failure = .notAllowed
            case nil: failure = nil
            case let other?: Issue.record("\(label): unknown failure \(other)")
            }
            let input = MacReachabilityInput(
                isOnline: i["is_online"] as? Bool ?? false,
                quietMs: (i["quiet_ms"] as? NSNumber).map { $0.int64Value },
                connection: connection, failure: failure,
                live: i["live"] as? Bool ?? true, phoneOffline: i["phone_offline"] as? Bool ?? false)
            let kind = macReachabilityResolve(input: input)
            let expect = try #require(c["expect"] as? [String: Any])
            #expect(name(kind) == expect["kind"] as? String, "\(label)")
            switch kind {
            case .slow(let quiet): #expect(quiet == (expect["quiet_seconds"] as? NSNumber)?.int64Value, "\(label)")
            case .noAnswer(let online): #expect(online == expect["listed_online"] as? Bool, "\(label)")
            default: break
            }
            let action: String? = switch macReachabilityAction(state: kind) {
            case .retry: "Retry"
            case .signIn: "SignIn"
            case nil: nil
            }
            #expect(action == c["action"] as? String, "\(label): action")
        }
        #expect(macReachabilitySpan(seconds: 40) == "40 s")
    }
}
