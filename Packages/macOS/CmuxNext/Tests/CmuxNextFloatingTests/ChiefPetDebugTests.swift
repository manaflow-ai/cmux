#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextFloating
import Foundation
import Testing

/// `debug.chief_pet` (ChiefPetController+Debug): captures drive the pet as a person does. Its reply box opens,
/// takes text and sends it through the box's own submit (to the mini's chat it stays open), a drag moves the
/// panel through the view's mouse handlers, and a snapshot writes the panel's layers to a PNG.
@MainActor @Suite(.serialized) struct ChiefPetDebugTests {
    final class Sent {
        var messages: [(ChiefPetReplyTarget, String)] = []
    }

    static func controller(_ sent: Sent) -> ChiefPetController {
        let name = "ChiefPetDebugTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return ChiefPetController(makePanel: { ChiefPetPanel(defaults: defaults) },
                                  actions: ChiefPetActions(open: { _ in }, send: { target, text in
                                      sent.messages.append((target, text))
                                      return true
                                  }))
    }

    static let chat = ChiefPetSubject.Chat(host: "install:test", session: "s-1")

    @Test func openTypeAndSendReachTheMinisChatAndKeepTheBoxOpen() async {
        let sent = Sent()
        let controller = Self.controller(sent)
        defer { controller.closeReply(); controller.sync(false) }
        controller.sync(true)
        controller.setHome(ChiefPetHome(chat: Self.chat, title: "Coordinator", latest: "lane 2 merged"))
        #expect(controller.debug("type", ["text": "hi"])["error"] != nil, "no box yet")
        #expect(controller.debug("open_reply", [:])["reply_open"] as? Bool == true)
        let typed = controller.debug("type", ["text": "status?"])
        #expect(typed["reply_text"] as? String == "status?")
        #expect(typed["reply_latest"] as? String == "lane 2 merged", "the chat's newest reply shows under the field")
        _ = controller.debug("send", [:])
        for _ in 0..<50 where controller.sending || sent.messages.isEmpty { await Task.yield() }
        #expect(sent.messages.map(\.1) == ["status?"])
        if case .chat(let chat, _) = sent.messages.first?.0 { #expect(chat == Self.chat) } else { Issue.record("sent to \(String(describing: sent.messages.first?.0))") }
        let after = controller.debug("state", [:])
        #expect(after["reply_open"] as? Bool == true, "to the mini's chat the box stays open")
        #expect(after["reply_text"] as? String == "", "a sent message leaves the field")
    }

    @Test func aDragMovesThePanelAndHoldsUntilTheDrop() {
        let controller = Self.controller(Sent())
        defer { _ = controller.debug("drop", [:]); controller.sync(false) }
        controller.sync(true)
        guard let panel = controller.panel else { return Issue.record("no pet") }
        let start = panel.frame.origin
        let held = controller.debug("drag", ["dx": -40.0, "dy": 0.0, "steps": 4, "release": false])
        #expect(held["dragging"] as? Bool == true)
        #expect(panel.frame.origin.x == start.x - 40)
        #expect(controller.debug("drop", [:])["dragging"] as? Bool == false)
        #expect(controller.debug("drop", [:])["error"] != nil, "no press is left")
    }

    @Test func aSnapshotWritesThePetsLayers() {
        let controller = Self.controller(Sent())
        defer { controller.sync(false) }
        controller.sync(true)
        let path = FileManager.default.temporaryDirectory.appending(path: "chief-pet-\(UUID().uuidString).png").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let answer = controller.debug("snapshot", ["window": "pet", "path": path])
        #expect(answer["error"] == nil, "\(answer)")
        #expect((answer["width"] as? Int ?? 0) > 0)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(controller.debug("snapshot", ["window": "reply", "path": path])["error"] != nil, "no box open")
    }
}
#endif
