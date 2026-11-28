@testable import CmuxMobileLive
import CmuxMobileTransport
import Foundation
import Testing

/// The phone's side of `phone-page` (RFD 0089): one answer line per request
/// line, matched by id, in the host's wire (`cmux_phone_page`).
@MainActor
@Suite(.serialized) struct PhonePageChannelTests {
    func object(_ line: Data) -> [String: Any] {
        #expect(line.last == UInt8(ascii: "\n"))
        return (try? JSONSerialization.jsonObject(with: line.dropLast())) as? [String: Any] ?? [:]
    }

    @Test func aVerbIsAnsweredWithItsIdAndValue() async {
        PhonePageChannel.answer = { method, params, macID in
            .success(["method": method, "tab": params["tab"] as? String ?? "", "mac": macID])
        }
        defer { PhonePageChannel.answer = nil }
        let request = Data(#"{"id":7,"method":"browser.page.state","params":{"tab":"tab_1"}}"#.utf8)
        let answer = object(await PhonePageChannel.answerLine(request, macID: "mac-1"))
        #expect(answer["id"] as? Int == 7)
        #expect(answer["ok"] as? Bool == true)
        let value = answer["value"] as? [String: Any]
        #expect(value?["method"] as? String == "browser.page.state")
        #expect(value?["tab"] as? String == "tab_1")
        #expect(value?["mac"] as? String == "mac-1")
    }

    @Test func aRefusalKeepsItsCode() async {
        PhonePageChannel.answer = { _, _, _ in .failure(.init(code: "tab_not_on_phone", message: "mirrored")) }
        defer { PhonePageChannel.answer = nil }
        let request = Data(#"{"id":3,"method":"browser.page.eval","params":{"tab":"tab_1","script":"1"}}"#.utf8)
        let error = object(await PhonePageChannel.answerLine(request, macID: "mac-1"))["error"] as? [String: Any]
        #expect(error?["code"] as? String == "tab_not_on_phone")
        #expect(error?["message"] as? String == "mirrored")
    }

    @Test func noBrowserAndABadLineAreRefused() async {
        PhonePageChannel.answer = nil
        let request = Data(#"{"id":4,"method":"browser.page.back","params":{"tab":"tab_1"}}"#.utf8)
        let none = object(await PhonePageChannel.answerLine(request, macID: "m"))
        #expect(none["id"] as? Int == 4)
        #expect((none["error"] as? [String: Any])?["code"] as? String == "tab_not_on_phone")
        let bad = object(await PhonePageChannel.answerLine(Data("not json".utf8), macID: "m"))
        #expect((bad["error"] as? [String: Any])?["code"] as? String == "bad_request")
    }

    @Test func oversizedLinesCloseBeforeBeingAnswered() async {
        let oversized = Data(repeating: UInt8(ascii: "x"), count: PhonePageChannel.maxLine + 1)
        let newline = Data([UInt8(ascii: "\n")])
        for frames in [[oversized], [oversized + newline], [Data(oversized.dropLast()), Data(oversized.suffix(1)) + newline]] {
            let link = PageFramesLink(frames)
            await PhonePageChannel.serve(on: link, macID: "mac-1", deviceName: "iPhone")
            #expect(link.closedCode == "too_large")
            #expect(link.replies == 0)
        }
    }
}

private final class PageFramesLink: MacLink, LinkChannel, @unchecked Sendable {
    let id: UInt32 = 1
    let transport = TransportKind.wireGuard
    let states: AsyncStream<LinkState> = AsyncStream { $0.finish() }
    private let lock = NSLock()
    private var frames: [Data]
    private var code: String?
    private var sent = 0
    init(_ frames: [Data]) { self.frames = frames }
    var closedCode: String? { lock.withLock { code } }
    var replies: Int { lock.withLock { sent } }
    func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel { self }
    func ping() async throws -> UInt32 { 0 }
    func close() async {}
    func receive() async throws -> Data? { lock.withLock { frames.isEmpty ? nil : frames.removeFirst() } }
    func send(_ data: Data) async throws { lock.withLock { sent += 1 } }
    func close(code: String, reason: String) async { lock.withLock { self.code = code } }
}
