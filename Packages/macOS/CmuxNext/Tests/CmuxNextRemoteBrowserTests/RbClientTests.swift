import AppKit
import Foundation
import Testing
@testable import CmuxNextRemoteBrowser
import CmuxNextRemoteView

#if DEBUG
/// The Swift wrapper over the Rust client reducer (cmux_rb_client_*): host
/// bodies and the person's answers in, typed effects out, in the shapes of
/// schemas/remote-tab/client.json.
@Suite(.timeLimit(.minutes(1)))
struct RbClientTests {
    static func body(_ json: String) throws -> RemoteRdJSON {
        try JSONDecoder().decode(RemoteRdJSON.self, from: Data(json.utf8))
    }

    static let contextMenu = #"{"t":"rb.menu.show","token":1,"menu":{"kind":"context","anchor":{"x":12.0,"y":30.0,"width":0.0,"height":0.0},"surface":0,"items":[{"id":100,"type":"command","label":"Back","enabled":true,"checked":false,"items":[]},{"id":-1,"type":"separator","label":"","enabled":true,"checked":false,"items":[]},{"id":50150,"type":"command","label":"Copy","enabled":true,"checked":false,"items":[]}],"selected":null,"multiple":false,"right_aligned":false}}"#

    @Test func theLinkedCoreHasTheRbClientABI() {
        #expect(RemoteRdCore.abiVersion >= 2)
        #expect(RbClient() != nil)
    }

    @Test func aMenuOpensAndItsChoiceGoesBackOnce() throws {
        let client = try #require(RbClient())
        let shown = try client.apply(.host(Self.body(Self.contextMenu)))
        guard case let .showMenu(token, menu)? = shown.effects.first else { Issue.record("\(shown)"); return }
        #expect(token == 1)
        #expect(menu.kind == "context")
        #expect(menu.anchor == RbRect(x: 12, y: 30, width: 0, height: 0))
        #expect(menu.items.map(\.label) == ["Back", "", "Copy"])
        let chosen = try client.apply(.menuChosen(token: 1, choice: .command(50150)))
        #expect(chosen.effects == [.send(try Self.body(#"{"t":"rb.menu.result","token":1,"choice":{"choice":"command","id":50150}}"#))])
        let again = try client.apply(.menuChosen(token: 1, choice: .cancel))
        #expect(again.effects.isEmpty)
        #expect(again.note == "stale_answer")
    }

    @Test func navigateAndOpenTabRoundTrip() throws {
        let client = try #require(RbClient())
        let navigate = try client.apply(.navigate("https://example.com/typed"))
        #expect(navigate.effects == [.send(try Self.body(#"{"t":"rb.navigate","url":"https://example.com/typed"}"#))])
        let open = try client.apply(.host(Self.body(#"{"t":"rb.open_tab","request":1,"url":"https://example.com/link-1","disposition":"background_tab","user_gesture":true}"#)))
        #expect(open.effects == [.openTab(request: 1, url: "https://example.com/link-1", disposition: "background_tab", userGesture: true)])
        let answered = try client.apply(.tabOpened(request: 1, tab: "tab-2", refused: nil))
        #expect(answered.effects == [.send(try Self.body(#"{"t":"rb.open_tab.result","request":1,"tab":"tab-2","refused":null}"#))])
    }

    @Test func pageCursorAndUnhandledKeysBecomeEffects() throws {
        let client = try #require(RbClient())
        let page = try client.apply(.host(Self.body(#"{"t":"rb.page","url":"https://example.com/a","title":"A","loading":false,"can_go_back":true,"can_go_forward":false}"#)))
        #expect(page.effects == [.page(url: "https://example.com/a", title: "A", loading: false, canGoBack: true, canGoForward: false)])
        let cursor = try client.apply(.host(Self.body(#"{"t":"rb.cursor","cursor":{"kind":"pointer","hash":null}}"#)))
        #expect(cursor.effects == [.setCursor(kind: "pointer", hash: nil)])
        let key = try client.apply(.host(Self.body(#"{"t":"rb.key_unhandled","input_seq":7}"#)))
        #expect(key.effects == [.keyUnhandled(inputSeq: 7)])
    }

    @Test func viewerMessagesFromTheHostAreRejectedAndJunkIsInvalid() throws {
        let client = try #require(RbClient())
        let wrong = try client.apply(.host(Self.body(#"{"t":"rb.close"}"#)))
        #expect(wrong.reject == "wrong_direction")
        #expect(throws: RbClientError.invalid) { try client.apply(.host(.object(["t": .string("rb.nope")]))) }
    }

    @Test func aDialogClosesWhenTheSessionCrashes() throws {
        let client = try #require(RbClient())
        let shown = try client.apply(.host(Self.body(#"{"t":"rb.dialog.show","token":3,"dialog":{"kind":"prompt","origin":"https://example.com","message":"Name?","default_text":"x","is_reload":false}}"#)))
        #expect(shown.effects == [.showDialog(token: 3, dialog: RbDialog(kind: "prompt", origin: "https://example.com", message: "Name?", defaultText: "x", isReload: false))])
        let crashed = try client.apply(.host(Self.body(#"{"t":"rb.state","state":"crashed"}"#)))
        #expect(crashed.effects == [.closeDialog(token: 3), .session(state: "crashed")])
    }
}

/// AppKit events to rb/1 input events, and the record URL of a remote tab.
/// AppKit events and cursors are main-thread objects.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct RemoteBrowserInputEncoderTests {
    @Test func rightClickIsDOMButtonTwoAndCmdClickCarriesTheCommandBit() throws {
        let right = try #require(RemoteBrowserInputEncoder.pointer(type: .rightMouseDown, button: 1, clickCount: 1, modifierFlags: [], at: CGPoint(x: 12, y: 30)))
        guard case let .object(r) = right else { Issue.record("not an object"); return }
        #expect(r["e"] == .string("pointer"))
        #expect(r["kind"] == .string("down"))
        #expect(r["button"] == .int(2))
        #expect(r["x"] == .double(12))
        let cmd = try #require(RemoteBrowserInputEncoder.pointer(type: .leftMouseDown, button: 0, clickCount: 1, modifierFlags: [.command], at: .zero))
        guard case let .object(c) = cmd else { Issue.record("not an object"); return }
        #expect(c["button"] == .int(0))
        #expect(c["modifiers"] == .int(8))
        #expect(RemoteBrowserInputEncoder.pointer(type: .keyDown, button: 0, clickCount: 0, modifierFlags: [], at: .zero) == nil)
    }

    @Test func aSynthesizedRightClickWithButtonZeroIsStillTheSecondaryButton() throws {
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        guard case let .object(r)? = RemoteBrowserInputEncoder.pointer(event, at: .zero) else { Issue.record("no pointer"); return }
        #expect(r["button"] == .int(2))
        #expect(r["buttons"] == .int(2))
    }

    @Test func keyCodesBecomeDOMCodes() throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0, windowNumber: 0,
                                                  context: nil, characters: "A", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        guard case let .object(k)? = RemoteBrowserInputEncoder.key(event) else { Issue.record("no key"); return }
        #expect(k["code"] == .string("KeyA"))
        #expect(k["key"] == .string("A"))
        #expect(k["text"] == .string("A"))
        #expect(k["modifiers"] == .int(1))
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                  context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        guard case let .object(e)? = RemoteBrowserInputEncoder.key(enter) else { Issue.record("no key"); return }
        #expect(e["code"] == .string("Enter"))
        #expect(e["key"] == .string("Enter"))
        #expect(e["text"] == .string(""))
    }

    @Test func recordsAcceptOnlyLoopbackPorts() throws {
        #expect(RemoteBrowserTabRecord(address: "127.0.0.1:4103")?.endpoint.port == 4103)
        #expect(RemoteBrowserTabRecord(address: " localhost:5000 ")?.address == "127.0.0.1:5000")
        #expect(RemoteBrowserTabRecord(address: "4104")?.address == "127.0.0.1:4104")
        #expect(RemoteBrowserTabRecord(address: "example.com:4103") == nil)
        #expect(RemoteBrowserTabRecord(address: "127.0.0.1:80") == nil)
        let record = try #require(RemoteBrowserTabRecord(address: "4103", initialURL: URL(string: "https://example.com/a?b=c")))
        #expect(RemoteBrowserTabRecord.matches(record.url))
        #expect(RemoteBrowserTabRecord(url: record.url) == record)
        let file = try #require(URL(string: "cmux://remote-browser?address=4103&url=file:///etc/passwd"))
        #expect(RemoteBrowserTabRecord(url: file)?.initialURL == nil)
    }

    @Test func cssCursorsMapToAppKitCursorShapes() {
        // Shapes, not NSCursor objects: NSCursor needs a GUI session, and
        // this suite also runs in the headless lane.
        let mapped = ["pointer", "text", "grabbing", "ew-resize", "no-such-cursor"].map(RemoteBrowserCursorShape.init(css:))
        #expect(mapped == [.pointingHand, .iBeam, .closedHand, .resizeLeftRight, .arrow])
    }
}
#endif
