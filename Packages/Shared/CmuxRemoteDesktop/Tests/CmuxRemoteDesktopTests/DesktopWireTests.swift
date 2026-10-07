import CmuxBrowserStream
import CmuxMobileWire
import CmuxRemoteDesktop
import Foundation
import Testing

@Suite("desktop/1 wire (schemas/remote-desktop/desktop.json)")
struct DesktopWireTests {
    @Test func everyMessageDecodesAndReencodesToTheSameValue() throws {
        let messages = Vectors.list("messages")
        #expect(messages.count >= 19)
        for value in messages {
            let message = try DesktopMessage(json: value)
            #expect(Vectors.normalized(message.jsonValue) == Vectors.normalized(value), "\(value)")
        }
    }

    @Test func invalidMessagesAreRefused() {
        let invalid = Vectors.list("invalid")
        #expect(!invalid.isEmpty)
        for value in invalid {
            #expect(throws: RdWireError.self, "\(value)") { try DesktopMessage(json: value) }
        }
    }

    @Test func openParamsRoundTrip() throws {
        let cases = Vectors.list("open_params")
        #expect(cases.count == 4)
        for value in cases {
            let params = try RemoteDesktopChannelParams(params: value.objectValue ?? [:])
            #expect(Vectors.normalized(.object(params.params)) == Vectors.normalized(value), "\(value)")
        }
        let vnc = try RemoteDesktopChannelParams(params: cases[3].objectValue ?? [:])
        #expect(vnc.target == .vnc(try VncAddress(host: "10.0.0.12", port: 5901, name: "build-vm")))
    }

    @Test func invalidOpenParamsAreRefused() {
        let cases = Vectors.list("invalid_open_params")
        #expect(cases.count == 7)
        for value in cases {
            #expect(throws: RdWireError.self, "\(value)") { try RemoteDesktopChannelParams(params: value.objectValue ?? [:]) }
        }
    }

    @Test func theA0ShorthandOpensADisplayInViewMode() throws {
        let params = try RemoteDesktopChannelParams(params: ["service": .string("desktop"), "display": .int(0)])
        #expect(params.target == .display(0))
        #expect(params.mode == .view)
    }

    @Test func openedRoundTrips() throws {
        let value = try #require(Vectors.list("opened").first)
        let opened = try RemoteDesktopChannelOpened(params: value.objectValue ?? [:])
        #expect(opened.displays.count == 2)
        #expect(opened.cursor == .local)
        #expect(opened.view.pixelWidth == 1178)
        #expect(Vectors.normalized(.object(opened.params)) == Vectors.normalized(value))
    }

    @Test func aPasswordNeverPrints() {
        let message = DesktopMessage.auth(password: "hunter22")
        #expect(!"\(message)".contains("hunter22"))
        #expect(!"\(DesktopMessage.clipboardPush(seq: 1, text: "secret"))".contains("secret"))
    }

    @Test func vncAddressesAreHostsNotURLs() throws {
        #expect(try VncAddress(host: "[::1]").host == "::1")
        #expect(try VncAddress(host: "::1").isLoopback)
        #expect(try VncAddress(host: "localhost").isLoopback)
        #expect(try !VncAddress(host: "mac-mini.tail1234.ts.net").isLoopback)
        for bad in ["", "a b", "http://x", "x/y", "u@x", "-x", "x?y"] {
            #expect(throws: RdWireError.self, "\(bad)") { try VncAddress(host: bad) }
        }
        #expect(throws: RdWireError.self) { try VncAddress(host: "x", port: 70000) }
    }

    @Test func payloadsCarryDesktopControlAndDatagrams() throws {
        let control = DesktopPayload.control(.select(display: 2))
        #expect(try DesktopPayload(record: control.encoded()) == control)
        let datagram = DesktopPayload.datagram(RdDatagramHeader(kind: .inputAck), RdInputAck(appliedSeq: 9).encoded)
        #expect(try DesktopPayload(record: datagram.encoded()) == datagram)
        let rb = RdControlMessage.service(service: "rb/1", body: .object(["t": .string("rb.close")]))
        let other = try DesktopPayload(record: DesktopPayload.otherControl(rb).encoded())
        #expect(other == .otherControl(rb))
    }
}
