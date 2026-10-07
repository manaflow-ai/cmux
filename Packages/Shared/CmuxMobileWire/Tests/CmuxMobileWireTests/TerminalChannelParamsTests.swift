import Foundation
import Testing
@testable import CmuxMobileWire

@Suite struct TerminalChannelParamsTests {
    let fixtures = Fixtures()

    private func frames(_ phase: String) throws -> [MobileFrame] {
        try #require(fixtures.json("fixtures/terminal.json")["cases"]?.arrayValue)
            .filter { ($0["phase"]?.stringValue ?? "request") == phase && $0["message"]?.stringValue == "terminal" }
            .map { try MobileFrame(value: $0["frame"]!) }
    }

    @Test func openParamsDecodeTypedAndBack() throws {
        guard case .channelOpen(let open) = try #require(frames("request").first) else {
            Issue.record("not a channel.open")
            return
        }
        let params = try JSONValue.object(open.params).decode(as: TerminalChannelParams.self)
        #expect(params.terminal == "term_t01")
        #expect(params.viewport == TerminalViewport(cols: 46, rows: 38, pxWidth: 1179, pxHeight: 2100))
        #expect(params.snapshot.versions == [1])
        #expect(try JSONValue(encoding: params) == .object(open.params))
    }

    @Test func openedParamsKeepAnExplicitNullVersion() throws {
        let opened = try frames("opened").compactMap { frame -> ChannelOpenedFrame? in
            if case .channelOpened(let f) = frame { return f }
            return nil
        }
        #expect(opened.count == 2)
        for frame in opened {
            let params = try JSONValue.object(frame.params).decode(as: TerminalOpenedParams.self)
            #expect(try JSONValue(encoding: params) == .object(frame.params))
        }
        let fallback = try JSONValue.object(opened[1].params).decode(as: TerminalOpenedParams.self)
        #expect(fallback.snapshotVersion == nil)
        #expect(try JSONValue(encoding: fallback)["snapshot_version"] == .null)
    }
}
