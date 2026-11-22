import AppKit
import Foundation
import Testing
@testable import CmuxNextOnboarding

/// The chats step: shown after Projects when the App can open agent chats,
/// nothing checked, the keyboard cursor and Space, and Continue resuming
/// each checked chat once.
@MainActor
@Suite struct ChatsStepTests {
    func settle(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
    }

    func chat(_ id: String, _ app: AgentApp = .claudeCode) -> AgentChat {
        AgentChat(sessionID: id, app: app, folder: URL(fileURLWithPath: "/work/app"), title: "Chat \(id)", prompts: 2, lastActive: Date())
    }

    func services(_ chats: [AgentChat]) -> MockOnboardingServices {
        let services = MockOnboardingServices()
        services.firstTaskView = NSView()
        services.agentChats = chats
        return services
    }

    @Test func theStepFollowsProjectsOnlyWhenTheAppCanOpenChats() {
        #expect(!OnboardingModel(services: MockOnboardingServices(), start: .projects).steps.contains(.chats))
        #expect(OnboardingModel(services: services([]), start: .projects).steps == [.projects, .chats])
    }

    /// The chats classic cmux had open come checked, listed even past the
    /// newest rows.
    @Test func chatsOpenInClassicComeChecked() async {
        let older = (0..<ChatsStepModel.listed).map { chat("n\($0)") }
        let services = services(older + [chat("old"), chat("x", .codex)])
        services.classicOpenChats = ["claudeCode:old", "codex:x", "claudeCode:gone"]
        let model = OnboardingModel(services: services, start: .projects)
        model.stepDidAppear()
        await settle { model.chats.scanned }
        #expect(model.chats.selected == ["claudeCode:old", "codex:x"])
        #expect(model.chats.chats.count == ChatsStepModel.listed + 2)
    }

    /// The projects step starts the scan; nothing is checked, so Continue alone resumes nothing.
    @Test func theListArrivesEarlyWithNothingChecked() async {
        let services = services([chat("a"), chat("b", .codex)])
        let model = OnboardingModel(services: services, start: .projects)
        model.stepDidAppear()
        await settle { model.chats.scanned }
        #expect(model.chats.chats.map(\.sessionID) == ["a", "b"] && model.chats.selected.isEmpty)
        model.go(to: .chats)
        model.next()
        #expect(services.resumedChats.isEmpty && services.ended == true)
    }

    /// Continue resumes the checked chats once and ends the run (chats come last).
    @Test func continueResumesEachCheckedChatOnce() async {
        let services = services([chat("a"), chat("b", .codex), chat("c")])
        let model = OnboardingModel(services: services, start: .chats)
        model.stepDidAppear()
        await settle { model.chats.scanned }
        model.chats.toggle(model.chats.chats[0])
        model.chats.toggle(model.chats.chats[1])
        model.next()
        model.next()
        #expect(services.resumedChats.map { $0.map(\.sessionID) } == [["a", "b"]])
        #expect(services.ended == true)
    }

    /// ↓ and ↑ move a cursor that stays on the list; Space checks the row under it.
    /// Other keys go on to the flow.
    @Test func arrowsMoveTheCursorAndSpaceChecks() async throws {
        let model = OnboardingModel(services: services([chat("a"), chat("b"), chat("c")]), start: .chats)
        model.stepDidAppear()
        await settle { model.chats.scanned }
        let view = ChatsStepView(model: model.chats)
        func press(_ keyCode: UInt16, _ characters: String) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                      context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                                      isARepeat: false, keyCode: keyCode))
            view.keyDown(with: event)
        }
        try press(126, "")
        #expect(model.chats.cursor == 0, "the cursor stays on the first row")
        try press(125, "")
        try press(125, "")
        try press(125, "")
        #expect(model.chats.cursor == 2, "and on the last")
        try press(49, " ")
        #expect(model.chats.chosen.map(\.sessionID) == ["c"])
        try press(49, " ")
        #expect(model.chats.chosen.isEmpty)
        model.finish(completed: false)
    }

    /// A click on a row (press and release inside it) toggles that row, as a button does.
    @Test func aClickOnARowTogglesIt() throws {
        var toggled = 0
        let row = ChatRow(chat: chat("a"), now: Date()) { toggled += 1 }
        row.frame = NSRect(x: 0, y: 0, width: 400, height: ChatRow.height)
        func mouse(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        row.mouseDown(with: try mouse(.leftMouseDown, at: NSPoint(x: 40, y: 10)))
        row.mouseUp(with: try mouse(.leftMouseUp, at: NSPoint(x: 40, y: 10)))
        #expect(toggled == 1)
        row.mouseDown(with: try mouse(.leftMouseDown, at: NSPoint(x: 40, y: 10)))
        row.mouseUp(with: try mouse(.leftMouseUp, at: NSPoint(x: 900, y: 10)))
        #expect(toggled == 1, "a release outside the row does nothing")
    }

    /// Toggling a row puts the cursor there, so the keys carry on from it.
    @Test func togglingARowMovesTheCursorThere() async {
        let model = OnboardingModel(services: services([chat("a"), chat("b"), chat("c")]), start: .chats)
        model.stepDidAppear()
        await settle { model.chats.scanned }
        model.chats.toggle(model.chats.chats[1])
        #expect(model.chats.cursor == 1)
        model.chats.moveCursor(1)
        model.chats.toggleAtCursor()
        #expect(model.chats.chosen.map(\.sessionID) == ["b", "c"])
    }

    @Test func aRowNamesItsProjectAgentPromptsAndAge() {
        let now = Date()
        let chat = AgentChat(sessionID: "a", app: .codex, folder: URL(fileURLWithPath: "/work/api"), title: "", prompts: 7, lastActive: now)
        let detail = ChatRow.detail(chat, now: now)
        #expect(detail.hasPrefix("api · Codex · \(OnboardingStrings.chatsPrompts(7)) · "))
    }
}
