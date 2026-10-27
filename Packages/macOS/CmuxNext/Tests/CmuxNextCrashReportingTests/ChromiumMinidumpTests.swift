import Foundation
import Testing
@testable import CmuxNextCrashReporting

/// p09-observability-105: a Chromium minidump leaves the Mac only redacted: allowlisted annotations with plain
/// values, no stack memory, no paths, no message streams, no install-wide client id.
@Suite struct ChromiumMinidumpTests {
    @Test func aPlantedURLAnnotationIsRemoved() throws {
        var fixture = MinidumpFixture()
        let original = fixture.data()
        #expect(original.containsText(MinidumpFixture.plantedURL), "the fixture plants the URL")
        let dump = try ChromiumMinidump(data: original)
        #expect(!dump.redacted.containsText("planted.example"))
        #expect(!dump.redacted.containsText("url-chunk"))
        #expect(dump.annotations == ["prod": "cmux-next", "ver": "154.0.8037.98-cef30", "plat": "OS X",
                                     "ptype": "renderer", "osarch": "arm64"])
    }

    @Test func stackMemoryPathsAndMessagesAreLeftOut() throws {
        var fixture = MinidumpFixture()
        let original = fixture.data()
        #expect(original.containsText(MinidumpFixture.stackSecret) && original.containsText("alice"))
        let dump = try ChromiumMinidump(data: original)
        #expect(!dump.redacted.containsText("stack-secret"))
        #expect(!dump.redacted.containsText("alice"))
        #expect(!dump.redacted.containsText("/Users"))
        #expect(!dump.redacted.containsText("crash-info.example"))
        #expect(dump.redacted.count == original.count, "redaction zeroes bytes in place; every offset stays valid")
        #expect(dump.redacted.containsText(MinidumpFixture.helperName), "module file names stay for symbolication")
        #expect(dump.mainModule == MinidumpFixture.helperName)
        #expect(dump.processID == 4242)
        #expect(dump.processType == "renderer")
        #expect(dump.writtenAt == Date(timeIntervalSince1970: 1_790_000_000))
    }

    @Test func theClientIDIsZeroedAndTheContextKept() throws {
        var fixture = MinidumpFixture()
        let dump = try ChromiumMinidump(data: fixture.data())
        #expect(dump.redacted.range(of: Data(repeating: 0x5A, count: 16)) == nil, "the install-wide client id is zeroed")
        #expect(dump.redacted.range(of: Data(repeating: 0x11, count: 16)) != nil, "the per-report id stays")
        #expect(dump.redacted.range(of: Data(repeating: 0xC7, count: 64)) != nil, "the thread context stays")
    }

    @Test func redactionIsIdempotent() throws {
        var fixture = MinidumpFixture()
        let once = try ChromiumMinidump(data: fixture.data())
        let twice = try ChromiumMinidump(data: once.redacted)
        #expect(twice.redacted == once.redacted)
        #expect(twice.annotations == once.annotations)
    }

    @Test func aValueWithAPathOrURLIsNotPlain() {
        #expect(ChromiumMinidump.isPlainValue("154.0.8037.98-cef30"))
        #expect(!ChromiumMinidump.isPlainValue("https://a.example/"))
        #expect(!ChromiumMinidump.isPlainValue("/Users/alice"))
        #expect(!ChromiumMinidump.isPlainValue(String(repeating: "a", count: 65)))
        #expect(!ChromiumMinidump.isPlainValue("caf\u{E9}"))
    }

    @Test func notAMinidumpOrTruncatedIsRefused() {
        #expect(throws: ChromiumMinidump.Failure.notMinidump) { try ChromiumMinidump(data: Data("PK\u{3}\u{4}".utf8)) }
        var fixture = MinidumpFixture()
        let whole = fixture.data()
        for cut in [40, whole.count / 2, whole.count - 1] {
            #expect(throws: ChromiumMinidump.Failure.self) { try ChromiumMinidump(data: whole.prefix(cut)) }
        }
    }
}
