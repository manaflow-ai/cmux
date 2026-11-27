@testable import CmuxMobileLive
import Foundation
import Testing

#if os(iOS) && DEBUG
/// Swift live code on a device: the `live-code` service's frames (cmux-mobile-host live_code.rs)
/// land in the engine's folder whole, checked, and only in a dev build launched for it.
@Suite struct LiveCodeLinkFeedTests {
    private static let abcDigest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    @Test func takesOnlyAPatchOrAnUndoWithAPlainName() throws {
        let patch = try #require(LiveCodeLinkFeed.header(Data(#"{"name":"patch-1.dylib","bytes":3,"sha256":"x"}"#.utf8)))
        #expect(patch.bytes == 3)
        #expect(LiveCodeLinkFeed.header(Data(#"{"name":"undo-1.rollback","bytes":0,"sha256":"x"}"#.utf8)) != nil)
        #expect(LiveCodeLinkFeed.header(Data(#"{"name":"undo-1.rollback","bytes":3,"sha256":"x"}"#.utf8)) == nil)
        #expect(LiveCodeLinkFeed.header(Data(#"{"name":"../p.dylib","bytes":3,"sha256":"x"}"#.utf8)) == nil)
        #expect(LiveCodeLinkFeed.header(Data(#"{"name":".p.dylib","bytes":3,"sha256":"x"}"#.utf8)) == nil)
        #expect(LiveCodeLinkFeed.header(Data(#"{"name":"status.json","bytes":3,"sha256":"x"}"#.utf8)) == nil)
        #expect(LiveCodeLinkFeed.header(Data(#"{"name":"p.dylib","bytes":999999999,"sha256":"x"}"#.utf8)) == nil)
        #expect(LiveCodeLinkFeed.header(Data("not json".utf8)) == nil)
    }

    @Test func aBodyMustMatchItsSizeAndDigest() {
        let header = LiveCodeLinkFeed.Header(name: "p.dylib", bytes: 3, sha256: Self.abcDigest)
        #expect(LiveCodeLinkFeed.verified(Data("abc".utf8), header))
        #expect(!LiveCodeLinkFeed.verified(Data("abd".utf8), header))
        #expect(!LiveCodeLinkFeed.verified(Data("ab".utf8), header))
    }

    @Test func aPatchAppearsWholeUnderItsName() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try LiveCodeLinkFeed.place(Data("abc".utf8), name: "p.dylib", in: folder)
        #expect(try Data(contentsOf: folder.appendingPathComponent("p.dylib")) == Data("abc".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["p.dylib"])
    }

    @Test func onlyCompleteNewLogLinesGoBack() {
        let data = Data("old\nlive code: applied p.dylib\nhalf".utf8)
        let (lines, next) = LiveCodeLinkFeed.lines(in: data, from: 4)
        #expect(lines == ["live code: applied p.dylib"])
        #expect(next == 31)
        #expect(LiveCodeLinkFeed.lines(in: data, from: next).lines.isEmpty)
    }

    @Test func onlyADevBuildLaunchedForItOpensTheService() {
        let on = ["CMUX_LIVE_CODE_LINK": "1"]
        #expect(LiveCodeLinkFeed.enabled(bundleID: "dev.cmux.mobile.dev", environment: on))
        #expect(!LiveCodeLinkFeed.enabled(bundleID: "dev.cmux.mobile.dev", environment: [:]))
        #expect(!LiveCodeLinkFeed.enabled(bundleID: "dev.cmux.app.internal", environment: on))
        #expect(!LiveCodeLinkFeed.enabled(bundleID: "com.cmux.app", environment: on))
    }
}
#endif
