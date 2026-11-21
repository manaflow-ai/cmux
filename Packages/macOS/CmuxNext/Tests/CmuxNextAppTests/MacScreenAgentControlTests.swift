import CmuxNextControl
@testable import CmuxNextMacScreen
import CmuxNextRemoteView
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

// `mac_screen.frame` and `mac_screen.input` (`cmux rd screenshot|click|type|key`, every build):
// they act only on a tab the person connected, and refuse with where the tab stands.

nonisolated private let agentDeviceID = "0b6c1a2e-3d4f-4a5b-8c9d-aabbccddee02"

@MainActor
struct MacScreenAgentControlTests {
    private func makePages() -> MacScreenPages {
        let file = FileManager.default.temporaryDirectory.appending(path: "mac-screen-\(UUID().uuidString)/mac-screen.json")
        return MacScreenPages(store: MacScreenStore(file: file), work: BackgroundWork())
    }

    private func refusalCode(_ body: () throws -> JSONValue) -> String? {
        do {
            _ = try body()
            return nil
        } catch let error as ControlError {
            return error.code
        } catch {
            return "\(error)"
        }
    }

    /// No tab, the home page, and a device tab at its Connect card each refuse; nothing connects.
    @Test func aTabNotStreamingRefusesWithItsState() {
        let pages = makePages()
        #expect(MacScreenPages.agentRefusal(nil, forInput: false) == "no_tab")
        pages.prepare("home", record: MacScreenRecord(macID: nil), byPerson: true)
        _ = pages.makeView(for: "home")
        #expect(MacScreenPages.agentRefusal(pages.tab("home"), forInput: true) == "no_tab")
        pages.prepare("a", record: MacScreenRecord(deviceID: agentDeviceID), byPerson: false)
        _ = pages.makeView(for: "a")
        let state = MacScreenPages.agentRefusal(pages.tab("a"), forInput: true)
        #expect(state == "connect_card" || state == "unsupported", "\(String(describing: state))")
        let code = refusalCode { try pages.agentInput(["tab": "a", "events": [["t": "key", "usage": 0x07_0004]]]) }
        #expect(code?.hasPrefix("mac_screen.") == true)
        #expect(pages.tab("a")?.pane?.model.hub?.phase.isPending != true, "a refusal asks the hub for nothing")
        #expect(refusalCode { try pages.agentInput(["tab": "gone", "events": []]) } == "mac_screen.no_tab")
        #expect(refusalCode { try pages.agentInput(["events": []]) } == "invalid_params")
        #expect(refusalCode { try pages.agentInput(["tab": "a", "events": [["t": "drag"]]]) } == "invalid_params")
        pages.tabClosed("a")
        pages.tabClosed("home")
    }

    /// Each refusal of the hub has its own state name for the CLI's next step.
    @Test func hubRefusalsHaveNames() {
        let names: [(MacScreenHubRefusal, String)] = [
            (.permissionNone, "permission_none"), (.scopeExceeds, "scope_exceeds"), (.hostOffline, "host_offline"),
            (.notShared, "not_shared"), (.notFound, "not_found"), (.notSignedIn, "not_signed_in"), (.other, "refused"),
        ]
        for (refusal, name) in names { #expect(MacScreenPages.refusalName(refusal) == name) }
    }

    /// The CLI's events become the pane's input events.
    @Test func eventsParseAsThePaneSendsThem() {
        #expect(MacScreenPages.agentEvents(["t": "pointer", "x": 960, "y": 270]) == [.pointer(x: 960, y: 270)])
        #expect(MacScreenPages.agentEvents(["t": "pointer", "x": -1, "y": 0]) == nil)
        #expect(MacScreenPages.agentEvents(["t": "button", "button": 3, "down": false]) == [.button(.right, down: false)])
        #expect(MacScreenPages.agentEvents(["t": "button", "button": 7]) == nil)
        #expect(MacScreenPages.agentEvents(["t": "key", "usage": 0x07_0028, "down": true]) == [.key(usage: 0x07_0028, down: true)])
        #expect(MacScreenPages.agentEvents(["t": "text", "text": "hello"]) == [.text("hello")])
        let long = String(repeating: "é", count: 300)
        #expect((MacScreenPages.agentEvents(["t": "text", "text": .string(long)])?.count ?? 0) > 1)
        #expect(MacScreenPages.agentEvents(["t": "text", "text": ""]) == nil)
    }

    /// The methods `cmux rd` sends are the ones the app registers.
    @Test func theCLISendsTheseMethods() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 6 { root.deleteLastPathComponent() }
        let source = try String(contentsOf: root.appendingPathComponent("cmux-tui/crates/cmux-tui/src/cli/rd_agent.rs"), encoding: .utf8)
        func constant(_ name: String) throws -> String {
            let line = try #require(source.split(separator: "\n").first { $0.contains("const \(name): &str = ") })
            return try #require(line.split(separator: "\"").dropFirst().first.map(String.init))
        }
        #expect(try constant("FRAME_METHOD") == MacScreenPages.agentMethods[0])
        #expect(try constant("INPUT_METHOD") == MacScreenPages.agentMethods[1])
    }
}
