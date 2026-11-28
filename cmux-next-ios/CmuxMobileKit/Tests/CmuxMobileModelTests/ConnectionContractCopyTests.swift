import Foundation
import Testing
@testable import CmuxMobileModel

/// The words a Mac's view shows for each state the connection contract resolves
/// (rust/crates/cmux-mobile-link-ffi/tests/fixtures/connection_contract.json, which Rust checks
/// `mac_reachability_resolve` against; map in cmux-next-ios/contract/README.md). A state Rust
/// adds, or one whose words the contract pins, fails here until ``MacReachability`` has it.
@Suite struct ConnectionContractCopyTests {
    static func contract(filePath: String = #filePath) throws -> [String: Any] {
        // Tests/CmuxMobileModelTests/<file> -> cmux-next-ios
        let root = URL(fileURLWithPath: filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("rust/crates/cmux-mobile-link-ffi/tests/fixtures/connection_contract.json")
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    static func reachability(kind: String, expect: [String: Any]) -> MacReachability? {
        switch kind {
        case "Connected": .connected
        case "Connecting": .connecting
        case "NotConnected": .notConnected
        case "Slow": .slow(quietSeconds: (expect["quiet_seconds"] as? NSNumber)?.intValue ?? 0)
        case "Offline": .offline(lastSeenAt: nil)
        case "NoAnswer": .noAnswer(listedOnline: expect["listed_online"] as? Bool ?? false, lastSeenAt: nil)
        case "ServiceDown": .serviceDown
        case "AuthRequired": .authRequired
        case "NotAllowed": .notAllowed
        case "PhoneOffline": .phoneOffline
        default: nil
        }
    }

    @Test func everyKindRustResolvesIsOneTheMacViewHas() throws {
        let kinds = try #require(Self.contract()["reachability_kinds"] as? [String])
        #expect(kinds.count == 10)
        for kind in kinds {
            #expect(Self.reachability(kind: kind, expect: [:]) != nil, "\(kind): a state Rust resolves and iOS cannot show")
        }
    }

    @Test func everyCaseShowsTheContractsWords() throws {
        let cases = try #require(Self.contract()["reachability"] as? [[String: Any]])
        var checked = 0
        for c in cases {
            let label = c["name"] as? String ?? "?"
            let expect = try #require(c["expect"] as? [String: Any])
            let kind = try #require(expect["kind"] as? String)
            guard let state = Self.reachability(kind: kind, expect: expect) else {
                Issue.record("\(label): unknown kind \(kind)")
                continue
            }
            guard let words = c["status_text"] as? String else { continue }
            #expect(state.statusText(now: Date()) == words, "\(label)")
            checked += 1
        }
        #expect(checked > 0)
    }
}
