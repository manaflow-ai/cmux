import AppKit
import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// `/` in a Chief chat's message box lists skills like Claude Code's slash commands (Lawrence
/// 2026-11-07: "i want to be able to invoke / skills from chief and have chief skills, like i want
/// all the emil skills in chief"). Drives a real `ChatController` in an offscreen window with real
/// key-downs, over a skill catalog in a temporary folder.
@MainActor @Suite(.serialized) struct SlashSkillMenuTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    @MainActor struct Pane {
        let window: NSWindow
        let controller: ChatController
        var field: FieldTextView { controller.demo!.compose.textView.view }
        var menuView: SlashSkillMenuView? { controller.host.slashMenuView }
    }

    /// A Chief home, its shared skills, and a Claude home with skills and one plugin.
    struct Folders {
        let root: URL
        var chiefHome: URL { root.appending(path: "chief/default") }
        var claudeHome: URL { root.appending(path: "claude") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "slash-skills-\(UUID().uuidString)")
            try skill(root.appending(path: "chief/skills"), "cmux-views", "Show agents and fleet views.")
            try skill(root.appending(path: "chief/default/skills"), "emil-color", "The Chief's own copy.")
            try skill(claudeHome.appending(path: "skills"), "emil-color", "The person's copy.")
            try skill(claudeHome.appending(path: "skills"), "emil-prototype", "Build several versions behind a live picker.")
            try skill(claudeHome.appending(path: "skills"), "emil-ui-polish", "The invisible details.")
            try FileManager.default.createDirectory(at: claudeHome.appending(path: "skills/not-a-skill"), withIntermediateDirectories: true)
            let plugin = root.appending(path: "cache/vercel/0.50.0")
            try skill(plugin.appending(path: "skills"), "ai-sdk", "The AI SDK.")
            try FileManager.default.createDirectory(at: claudeHome.appending(path: "plugins"), withIntermediateDirectories: true)
            let installed = ["version": 2, "plugins": ["vercel@claude-plugins-official": [["installPath": plugin.path], ["installPath": plugin.path]]]] as [String: Any]
            try JSONSerialization.data(withJSONObject: installed).write(to: claudeHome.appending(path: "plugins/installed_plugins.json"))
        }

        private func skill(_ dir: URL, _ name: String, _ description: String) throws {
            let folder = dir.appending(path: name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "---\nname: \(name)\ndescription: \"\(description)\"\n---\n\nSteps.\n".write(to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        }

        var catalog: SlashSkillCatalog { SlashSkillCatalog(chiefHome: chiefHome, claudeHome: claudeHome) }
    }

    private func pane(skills catalog: SlashSkillCatalog?) async -> Pane {
        let me = ParticipantID("user_me"), chief = ParticipantID("agent_chief")
        let people = [CmuxHomeCore.Participant(id: me, kind: .human, displayName: "Me"),
                      CmuxHomeCore.Participant(id: chief, kind: .agent, displayName: "Chief", agentClass: .chief)]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let items = [TranscriptItem(key: IdempotencyKey("k0"), seq: Seq(1), author: me, parts: [.text("an old ask")],
                                    createdAt: base, delivery: .committed, messageID: MessageID("msg_0"))]
        let summary = ConversationSummary(id: ConversationID("conv_slash"), title: "Chief", participants: people,
                                          lastSeq: Seq(1), createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
        var core = ProjectionCore(me: me)
        let (conv, w) = core.install(ConversationID("conv_slash"), items: items, summary: summary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let controller = ChatController(host: HostView(frame: NSRect(x: 0, y: 0, width: 600, height: 700)), wake: NoWake())
        window.contentView = controller.host
        controller.install(conv, windowStart: w.start, total: w.total)
        controller.host.layoutSubtreeIfNeeded()
        if let catalog {
            let source = SlashSkillSource(catalog: catalog)
            controller.slashSkills = source
            source.refresh()
            await source.settled()
        }
        window.makeFirstResponder(controller.demo!.compose.textView.view)
        return Pane(window: window, controller: controller)
    }

    private func key(_ code: UInt16, _ chars: String, in p: Pane, flags: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: p.window.windowNumber, context: nil,
                                     characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        p.field.keyDown(with: event)
    }
    private func down(_ p: Pane) { key(125, "\u{F701}", in: p, flags: [.function, .numericPad]) }
    private func up(_ p: Pane) { key(126, "\u{F700}", in: p, flags: [.function, .numericPad]) }
    private func tab(_ p: Pane) { key(48, "\t", in: p) }
    private func ret(_ p: Pane) { key(36, "\r", in: p) }
    private func esc(_ p: Pane) { key(53, "\u{1B}", in: p) }
    private func type(_ text: String, in p: Pane) { p.field.insertText(text, replacementRange: p.field.selectedRange()) }

    // MARK: The catalog

    @Test func theCatalogListsChiefThenClaudeThenPluginSkillsOnce() throws {
        let folders = try Folders()
        let got = folders.catalog.load().map { "\($0.name)|\(SlashSkillMenuView.sourceLabel($0.source))|\($0.summary)" }
        #expect(got == [
            "cmux-views|Chief|Show agents and fleet views.",
            "emil-color|Chief|The Chief's own copy.",
            "emil-prototype|Claude|Build several versions behind a live picker.",
            "emil-ui-polish|Claude|The invisible details.",
            "vercel:ai-sdk|vercel|The AI SDK.",
        ])
    }

    // MARK: The menu's state

    @Test func theMenuRanksNamePrefixThenWordThenNameThenDescription() throws {
        let skills = [SlashSkill(name: "emil-ui-polish", summary: "Polish.", source: .claude),
                      SlashSkill(name: "polish-all", summary: "x", source: .claude),
                      SlashSkill(name: "repolish", summary: "y", source: .claude),
                      SlashSkill(name: "review", summary: "Find polish issues.", source: .claude),
                      SlashSkill(name: "other", summary: "z", source: .claude)]
        let menu = try #require(SlashSkillMenu(text: "/Pol", caret: 4, skills: skills))
        #expect(menu.matches.map(\.name) == ["polish-all", "emil-ui-polish", "repolish", "review"])
        #expect(SlashSkillMenu(text: "/", caret: 1, skills: skills)?.matches.count == 5)
        #expect(SlashSkillMenu(text: "/tmp/x", caret: 6, skills: skills) == nil, "a path is no command")
        #expect(SlashSkillMenu(text: "say /pol", caret: 8, skills: skills) == nil)
        #expect(SlashSkillMenu(text: "/pol more", caret: 9, skills: skills) == nil, "the caret is past the command")
        let applied = try #require(menu.applied(to: "/Pol"))
        #expect(applied.text == "/polish-all " && applied.caret == 12)
        let inner = try #require(SlashSkillMenu(text: "/po the rest", caret: 2, skills: skills))
        #expect(inner.applied(to: "/po the rest")?.text == "/polish-all the rest")
    }

    // MARK: The live box

    @Test func slashOpensTheMenuAndTypingFiltersIt() async throws {
        let folders = try Folders()
        let p = await pane(skills: folders.catalog)
        type("/", in: p)
        let view = try #require(p.menuView, "no menu after /")
        #expect(view.state?.matches.count == 5)
        #expect(view.superview === p.controller.host)
        let field = p.controller.demo!.compose.fieldRect
        #expect(view.frame.maxY <= field.minY && view.frame.minX == field.minX && view.frame.width == field.width, "the menu sits above the box")
        type("emil-p", in: p)
        #expect(p.menuView?.state?.matches.map(\.name) == ["emil-prototype"])
        type(" ", in: p)
        #expect(p.menuView == nil, "a space ends the command")
    }

    @Test func arrowsChooseAndTabPicksTheSkill() async throws {
        let folders = try Folders()
        let p = await pane(skills: folders.catalog)
        type("/emil", in: p)
        #expect(p.controller.slashMenu?.choice?.name == "emil-color")
        down(p)
        #expect(p.controller.slashMenu?.choice?.name == "emil-prototype")
        down(p); down(p)
        #expect(p.controller.slashMenu?.choice?.name == "emil-color", "Down wraps")
        up(p)
        #expect(p.controller.slashMenu?.choice?.name == "emil-ui-polish", "Up wraps")
        up(p)
        tab(p)
        #expect(p.field.string == "/emil-prototype ")
        #expect(p.field.selectedRange() == NSRange(location: 16, length: 0))
        #expect(p.menuView == nil)
        #expect(p.controller.store?.state.ui.draft.text == "/emil-prototype ", "the draft follows the pick")
        type("make the sheet better", in: p)
        #expect(p.menuView == nil)
    }

    @Test func returnPicksAnUnfinishedCommandAndEscClosesTheMenu() async throws {
        let folders = try Folders()
        let p = await pane(skills: folders.catalog)
        type("/proto", in: p)
        ret(p)
        #expect(p.field.string == "/emil-prototype ", "Return picks instead of sending a half command")
        p.field.replaceAllText(with: "/emil")
        #expect(p.menuView != nil)
        esc(p)
        #expect(p.menuView == nil)
        #expect(p.field.string == "/emil", "Esc keeps the words")
        type("-", in: p)
        #expect(p.menuView != nil, "a new command opens it again")
    }

    @Test func aClickPicksTheRow() async throws {
        let folders = try Folders()
        let p = await pane(skills: folders.catalog)
        type("/emil", in: p)
        p.controller.pickSlashSkill(at: 2)
        #expect(p.field.string == "/emil-ui-polish ")
    }

    @Test func aChatWithoutSkillsShowsNoMenuAndKeepsItsHistoryArrows() async {
        let p = await pane(skills: nil)
        type("/", in: p)
        #expect(p.menuView == nil)
        p.field.replaceAllText(with: "")
        up(p)
        #expect(p.field.string == "an old ask")
    }

    @Test func theMenuIsSolidInLightAndDark() async throws {
        let folders = try Folders()
        let p = await pane(skills: folders.catalog)
        type("/", in: p)
        let view = try #require(p.menuView)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            view.appearance = NSAppearance(named: name)
            let color = try #require(view.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)))
            #expect(color.alphaComponent == 1, "rows under the menu would show through in \(name.rawValue)")
        }
    }
}
