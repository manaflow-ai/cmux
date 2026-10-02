import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// Palette steps that take input (a name, a number, a choice): Return and
/// Escape belong to the palette, the action runs on what was focused when
/// the palette opened, and a refusal shows its reason on the row instead of
/// the system beep. Dogfood report: "Rename Tab Group", then Return, beeped
/// and did nothing.
@MainActor
@Suite struct PaletteInputStepTests {
    static let captured: [ActionTargetRef] = [
        ActionTargetRef(kind: .tabGroup, id: "g1"), ActionTargetRef(kind: .tab, id: "t1"),
        ActionTargetRef(kind: .pane, id: "p1"), ActionTargetRef(kind: .screen, id: "s1"),
        ActionTargetRef(kind: .workspace, id: "w1"), ActionTargetRef(kind: .window, id: "win1"),
        ActionTargetRef(kind: .machine, id: "local"),
    ]

    final class Recorder {
        var runs: [ActionID: ActionInvocation] = [:]
        /// `true` for each refusal a caller received (the App's beep path is
        /// `!refusalHasCaller`).
        var refusalsWithCaller: [Bool] = []
    }

    /// A controller over the standard catalog whose context is `captured`.
    func makeController(bind: (ActionRegistry, Recorder) -> Void) -> (PaletteController, Recorder) {
        let registry = ActionRegistry.standard()
        let recorder = Recorder()
        registry.refusalObserver = { [weak registry] _ in recorder.refusalsWithCaller.append(registry?.refusalHasCaller ?? false) }
        // The App's sheet: the user confirms.
        registry.confirmationPresenter = { _, _, proceed in proceed() }
        bind(registry, recorder)
        var sources = MockPaletteData().sources
        sources.context = { Self.captured }
        let controller = PaletteController(registry: registry, sources: sources, frecencyPersistence: nil)
        open(controller)
        return (controller, recorder)
    }

    /// What `show()` does without putting a panel on screen.
    func open(_ controller: PaletteController) {
        controller.captureContext()
        controller.model.reset(to: controller.commandsPage())
    }

    /// Palette-served actions (their own text pages over the palette's
    /// sources, not the registry); `renameTabAndRenameWorkspaceSubmitOnReturn`
    /// and the navigation tests cover them.
    static let paletteServed: Set<ActionID> = ["renameTab", "renameWorkspace", "palette.terminalOpenDirectory",
                                               "palette.toggleSetting", "palette.searchShortcuts", "goToWorkspace", "palette.goToTab"]

    /// Palette-visible actions with a required text or number argument.
    static func inputActionIDs() -> [ActionID] {
        ActionRegistry.standard().descriptors.filter { descriptor in
            !paletteServed.contains(descriptor.id) && descriptor.isPaletteVisible && descriptor.arguments.contains { argument in
                guard argument.isRequired else { return false }
                switch argument.kind {
                case .string, .int: return true
                default: return false
                }
            }
        }.map(\.id)
    }

    /// Entries tried on a text step until the submit row enables.
    static let samples = ["1", "8080", "name", "https://cmux.dev", "tab-group:g1", "tab:t1", "pane:p1", "screen:s1",
                          "workspace:w1", "window:win1", "machine:local"]

    static func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    /// Every key the palette maps: Return, keypad Enter, Cmd-Return,
    /// Escape, Tab, Shift-Tab, arrows, Page Up/Down, Backspace, Cmd-K.
    static var paletteKeys: [NSEvent] {
        [key(36, "\r"), key(76, "\u{3}"), key(36, "\r", .command), key(48, "\t"), key(48, "\t", .shift),
         key(126, "\u{F700}"), key(125, "\u{F701}"), key(116, "\u{F72C}"), key(121, "\u{F72D}"),
         key(51, "\u{7F}"), key(40, "k", .command), key(53, "\u{1B}")]
    }

    // MARK: Every input action

    @Test func everyInputActionRunsOnReturnWithItsTextAndTheCapturedTarget() async {
        let ids = Self.inputActionIDs()
        #expect(ids.contains("tabGroup.rename"))
        for id in ids {
            let (controller, recorder) = makeController { registry, recorder in
                // The context the action needs (a cloud workspace, a viewer).
                registry.context.formUnion(registry.descriptor(for: id)?.requires ?? [])
                registry.bind(id, invoke: { recorder.runs[id] = $0 })
            }
            let model = controller.model
            guard let item = controller.makeRegistryProvider().makeItems().first(where: { $0.id == "action:\(id.rawValue)" }) else {
                Issue.record("\(id) is not in the palette")
                continue
            }
            model.run(item.primary, of: item)
            var steps = 0
            while recorder.runs[id] == nil, steps < 6 {
                steps += 1
                if model.isTextInput {
                    for sample in Self.samples {
                        model.query = sample
                        if model.rows.first?.item.isEnabled == true { break }
                    }
                }
                await model.settle()
                #expect(controller.handleKeyDown(Self.key(36, "\r")), "\(id): Return must be the palette's")
            }
            guard let invocation = recorder.runs[id] else {
                Issue.record("\(id) did not run on Return")
                continue
            }
            let descriptor = controller.registry.descriptor(for: id)
            for argument in descriptor?.arguments ?? [] where argument.isRequired {
                #expect(invocation[argument.name] != nil, "\(id) ran without \(argument.name)")
            }
            let expected = descriptor?.targets.lazy.compactMap { kind in Self.captured.first { $0.kind == kind } }.first
            #expect(invocation.target == expected, "\(id) must target what was focused when the palette opened")
            #expect(recorder.refusalsWithCaller.isEmpty)
        }
    }

    // MARK: Named actions from the report

    @Test func renameTabGroupRenamesTheGroupFocusedWhenThePaletteOpened() async {
        let (controller, recorder) = makeController { registry, recorder in
            registry.bind("tabGroup.rename", invoke: { recorder.runs["tabGroup.rename"] = $0 })
        }
        let model = controller.model
        model.query = "rename tab group"
        await model.settle()
        #expect(model.selectedRowID == "action:tabGroup.rename")
        #expect(controller.handleKeyDown(Self.key(36, "\r")))
        #expect(model.isTextInput)
        model.query = "api"
        #expect(controller.handleKeyDown(Self.key(36, "\r")))
        let run = recorder.runs["tabGroup.rename"]
        #expect(run?["name"] == .string("api"))
        #expect(run?.target == ActionTargetRef(kind: .tabGroup, id: "g1"))
    }

    @Test func renameTabAndRenameWorkspaceSubmitOnReturn() async {
        let (controller, _) = makeController { _, _ in }
        let model = controller.model
        for (query, expectedTitle) in [("rename tab", "Rename Tab"), ("rename workspace", "Rename Workspace")] {
            open(controller)
            model.query = query
            await model.settle()
            #expect(controller.handleKeyDown(Self.key(36, "\r")), "\(query)")
            #expect(model.isTextInput, "\(query) opens text entry")
            #expect(model.pageTitle.hasPrefix(expectedTitle))
            model.query = "renamed"
            #expect(controller.handleKeyDown(Self.key(36, "\r")))
            #expect(model.notice == nil)
        }
    }

    // MARK: Refusals and keys

    @Test func aRefusedInputActionShowsItsReasonAndNeverBeeps() async {
        let (controller, recorder) = makeController { registry, _ in
            registry.bind("tabGroup.rename", invoke: { _ in registry.refuse("the tab is not in a group") })
        }
        let model = controller.model
        // The controller shows the panel again here; the test process has
        // no app to show it in, so record the request instead.
        var reopened: [String] = []
        model.onRefusal = { reopened.append($0) }
        model.query = "rename tab group"
        await model.settle()
        #expect(controller.handleKeyDown(Self.key(36, "\r")))
        model.query = "api"
        #expect(controller.handleKeyDown(Self.key(36, "\r")))
        #expect(recorder.refusalsWithCaller == [true])
        #expect(reopened == ["the tab is not in a group"])
        #expect(model.notice?.text == "the tab is not in a group")
        #expect(model.isTextInput)
        #expect(model.rows.first?.item.subtitle == "the tab is not in a group")
        // Typing clears the notice.
        model.query = "api2"
        #expect(model.notice == nil)
    }

    @Test func aDestructiveActionStillAsksForConfirmationFromThePalette() {
        let registry = ActionRegistry.standard()
        var asked = false
        registry.confirmationPresenter = { _, _, _ in asked = true }
        let destructive = registry.descriptors.first { $0.isDestructive && $0.requires.isEmpty }?.id
        #expect(destructive != nil)
        guard let destructive else { return }
        registry.bind(destructive, invoke: { _ in })
        let reason = registry.reportingRefusal { registry.perform(destructive, invocation: ActionInvocation()) }
        #expect(asked)
        #expect(reason == nil)
    }

    @Test func noPaletteKeyReachesTheResponderChainOnATextStep() async {
        for key in Self.paletteKeys {
            let (controller, _) = makeController { registry, _ in registry.bind("tabGroup.rename", invoke: { _ in }) }
            let model = controller.model
            model.query = "rename tab group"
            await model.settle()
            _ = controller.handleKeyDown(Self.key(36, "\r"))
            #expect(model.isTextInput)
            // The step opens on the group's name; an emptied step is where
            // Backspace belongs to the palette (it steps back).
            model.query = ""
            #expect(controller.handleKeyDown(key), "key \(key.keyCode) \(key.modifierFlags.rawValue) fell through on a text step")
        }
    }

    /// Backspace on a step that holds a name edits the name (the field
    /// editor deletes the selected text); it never steps back.
    @Test func backspaceEditsAPrefilledName() async {
        let (controller, _) = makeController { registry, _ in registry.bind("tabGroup.rename", invoke: { _ in }) }
        let model = controller.model
        model.query = "rename tab group"
        await model.settle()
        _ = controller.handleKeyDown(Self.key(36, "\r"))
        #expect(model.query == "Review")
        #expect(!controller.handleKeyDown(Self.key(51, "\u{7F}")))
        #expect(model.isTextInput)
    }

    @Test func noPaletteKeyReachesTheResponderChainWithoutResults() async {
        for key in Self.paletteKeys {
            let (controller, _) = makeController { _, _ in }
            let model = controller.model
            model.query = "zzzzzz-no-such-command"
            await model.settle()
            #expect(model.rows.isEmpty)
            model.query = ""
            // Empty root (Backspace pops nothing) and an empty result list.
            #expect(controller.handleKeyDown(key), "key \(key.keyCode) fell through at the root")
            model.query = "zzzzzz-no-such-command"
            await model.settle()
            if key.keyCode != 51 {
                #expect(controller.handleKeyDown(key), "key \(key.keyCode) fell through with no results")
            }
        }
    }
}
