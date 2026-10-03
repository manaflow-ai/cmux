import Foundation
import Testing
@testable import CmuxNextRemoteView

struct RemoteViewTabRecordTests {
    @Test func roundTripsEveryTargetAndMode() throws {
        let targets: [RemoteViewTabRecord.Target] = [.display(0), .display(1), .display(UInt32.max), .window(42), .window(UInt64.max), .virtual]
        for target in targets {
            for mode in RemoteControlMode.allCases {
                let record = try #require(RemoteViewTabRecord(host: "mac_01.example-host", target: target, mode: mode))
                let parsed = try #require(RemoteViewTabRecord(url: record.url))
                #expect(parsed == record)
                #expect(RemoteViewTabRecord.matches(record.url))
            }
        }
    }

    @Test func urlHasFixedFieldOrder() throws {
        let record = try #require(RemoteViewTabRecord(host: "mock", target: .window(7), mode: .control))
        #expect(record.url.absoluteString == "cmux://remote-view?host=mock&target=window:7&mode=control")
    }

    @Test func missingTargetAndModeDefaultToFirstDisplayAndView() throws {
        let record = try #require(RemoteViewTabRecord(url: URL(string: "cmux://remote-view?host=mock")))
        #expect(record.target == .display(1))
        #expect(record.mode == .view)
    }

    @Test func matchesIsCaseInsensitiveOnSchemeAndHostOnly() {
        #expect(RemoteViewTabRecord.matches(URL(string: "CMUX://Remote-View?host=a")))
        #expect(RemoteViewTabRecord.matches(URL(string: "cmux://remote-view")))
        #expect(!RemoteViewTabRecord.matches(URL(string: "cmux://history")))
        #expect(!RemoteViewTabRecord.matches(URL(string: "https://remote-view/?host=a")))
        #expect(!RemoteViewTabRecord.matches(nil))
    }

    @Test func rejectsInvalidFields() {
        let bad = [
            "cmux://remote-view",                                         // no host
            "cmux://remote-view?host=",                                   // empty host
            "cmux://remote-view?host=-lead",                              // must start alphanumeric
            "cmux://remote-view?host=a%20b",                              // space
            "cmux://remote-view?host=a/b",                                // slash
            "cmux://remote-view?host=" + String(repeating: "a", count: 129),
            "cmux://remote-view?host=a&target=display:",                  // no id
            "cmux://remote-view?host=a&target=display:-1",                // sign
            "cmux://remote-view?host=a&target=display:+1",
            "cmux://remote-view?host=a&target=display:4294967296",        // above UInt32
            "cmux://remote-view?host=a&target=window:18446744073709551616",
            "cmux://remote-view?host=a&target=window:1:2",
            "cmux://remote-view?host=a&target=screen:1",
            "cmux://remote-view?host=a&target=Virtual",
            "cmux://remote-view?host=a&mode=admin",
            "cmux://remote-view?host=a&host=b",                           // repeated known field
            "cmux://remote-view?host=a&mode=view&mode=control",
            "cmux://remote-view?host",                                    // no value
            "cmux://remote-view?host=a:22",                               // no port in the name
            "cmux://u:p@remote-view?host=a",                              // user and password
            "cmux://remote-view:9?host=a",                                // port
            "cmux://remote-view/x?host=a",                                // path
            "cmux://remote-view?host=a#f",                                // fragment
        ]
        for text in bad {
            #expect(RemoteViewTabRecord(url: URL(string: text)) == nil, "\(text)")
        }
    }

    @Test func ignoresUnknownFields() throws {
        let record = try #require(RemoteViewTabRecord(url: URL(string: "cmux://remote-view?host=a&future=1&target=virtual")))
        #expect(record.target == .virtual)
    }

    @Test func hostLimitIsInclusive() {
        #expect(RemoteViewTabRecord(host: String(repeating: "a", count: 128)) != nil)
        #expect(RemoteViewTabRecord(host: String(repeating: "a", count: 129)) == nil)
        #expect(RemoteViewTabRecord(host: "é") == nil)
    }

    @Test func tabTitleIsTheHostOrAGenericTitle() throws {
        let record = try #require(RemoteViewTabRecord(host: "build-mini"))
        #expect(RemoteViewTabRecord.tabTitle(record) == "build-mini")
        #expect(!RemoteViewTabRecord.tabTitle(nil).isEmpty)
    }

    /// Property: every record built from random valid fields survives the URL.
    @Test func seededRandomRecordsRoundTrip() throws {
        var generator = SplitMix64(seed: 0x5EED_0017)
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        for _ in 0..<2000 {
            let length = Int(generator.next() % 128) + 1
            var host = String(alphabet[Int(generator.next() % 62)])
            for _ in 1..<length { host.append(alphabet[Int(generator.next() % UInt64(alphabet.count))]) }
            let target: RemoteViewTabRecord.Target = switch generator.next() % 3 {
            case 0: .display(UInt32(truncatingIfNeeded: generator.next()))
            case 1: .window(generator.next())
            default: .virtual
            }
            let mode: RemoteControlMode = generator.next() % 2 == 0 ? .view : .control
            let record = try #require(RemoteViewTabRecord(host: host, target: target, mode: mode))
            #expect(RemoteViewTabRecord(url: record.url) == record)
        }
    }
}

private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
