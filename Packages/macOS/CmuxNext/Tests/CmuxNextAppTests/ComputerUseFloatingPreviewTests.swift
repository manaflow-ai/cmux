import AppKit
@testable import CmuxNextComputerUsePreview
import CmuxNextDaemon
import Testing

/// The floating Computer Use preview (`computerUse.floatingPreview`, prototype). User 2026-11-22:
/// "WHERE IS THE FUCKING PREVIEW OF THE FUCKING RUNNING SITUATION AND THE ABILITY TO DRAG IT AROUND AND
/// FUCKING HIDE IT"; its constraint: "you're foregrounding shit", so the panel never takes focus.
@MainActor
struct ComputerUseFloatingPreviewTests {
    static func line(_ session: String, done: Bool? = false) -> CmuxNextDaemon.JSONValue {
        var line: [String: CmuxNextDaemon.JSONValue] = ["session": .string(session), "surface": .object(["chat": .string("c1")])]
        if let done {
            line["card"] = .object([
                "session": .string(session), "app": .string("Notes"), "done": .bool(done),
                "frame": .string("data:image/jpeg;base64,AA=="),
                "pointer": .object(["x": .number(0.25), "y": .number(0.5)]),
            ])
        } else {
            line["card"] = .null
        }
        return .object(line)
    }

    static func defaults() -> UserDefaults {
        let name = "cmux.tests.floatingPreview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// The panel is non-activating, floats on every Space and over full-screen apps, drags by its
    /// background, stays when cmux is in the background, and can never become key or main.
    @Test func thePanelNeverBecomesKeyOrMain() {
        let panel = ComputerUseFloatingPreviewPanel(contentRect: NSRect(x: 100, y: 100, width: 360, height: 225))
        #expect(!panel.canBecomeKey && !panel.canBecomeMain)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.level == .floating)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces) && panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.isMovableByWindowBackground && !panel.hidesOnDeactivate)
        panel.orderFrontRegardless()
        panel.makeKey()
        #expect(!panel.isKeyWindow && !panel.isMainWindow)
        panel.orderOut(nil)
    }

    /// Off by default: no card shows it. On: a running card shows it; the person's Hide hides it
    /// (and it stays hidden for the next card) until Show; the shown session going hides it unless
    /// the person asked for it.
    @Test func showAndHideToggle() {
        let preview = ComputerUseFloatingPreview(defaults: Self.defaults())
        preview.take(Self.line("s1"))
        #expect(!preview.isShown, "off by default")
        preview.enabled = true
        #expect(preview.isShown && preview.card?.session == "s1" && preview.card?.pointer == CGPoint(x: 0.25, y: 0.5))
        #expect(preview.panel.map { !$0.isKeyWindow } ?? true)
        preview.setShown(false)
        #expect(!preview.isShown)
        preview.take(Self.line("s2"))
        #expect(!preview.isShown, "a hidden panel stays hidden for the next card")
        preview.setShown(true)
        #expect(preview.isShown && preview.card?.session == "s2")
        preview.take(Self.line("s2", done: nil))
        #expect(preview.isShown && preview.card == nil, "the person's Show keeps it while no card is live")
        preview.setShown(false)
        preview.setShown(true)
        preview.setShown(false)
        #expect(!preview.isShown)
        preview.enabled = false
        preview.setShown(true)
        #expect(!preview.isShown, "the setting off never shows it")
    }

    /// One session shows: another session's done or gone line leaves it alone; a running one takes it.
    @Test func anotherSessionsEndLeavesTheShownCardAlone() {
        let preview = ComputerUseFloatingPreview(defaults: Self.defaults())
        preview.enabled = true
        preview.take(Self.line("new"))
        preview.take(Self.line("old", done: true))
        preview.take(Self.line("old", done: nil))
        #expect(preview.card?.session == "new")
        preview.take(Self.line("new", done: nil))
        #expect(preview.card == nil && !preview.isShown)
        preview.take(Self.line("other"))
        #expect(preview.card?.session == "other" && preview.isShown)
        preview.setShown(false)
    }
}
