@testable import CmuxNextApp
import Testing

/// One test per bug the input model fuzzer found (plans/cmux-next/input-spec.md
/// section 7). Reducer bugs are checked on the reducer itself; wiring bugs
/// replay the fuzzer's minimal sequence through the composed model, whose
/// `SimWindow` and `InputWorld` follow the fixed `FocusEffectApplier`,
/// `WindowManager` and `PaletteController` wiring.
struct InputBugRegressionTests {
    typealias R = FocusReducerTests

    static func noViolation(_ actions: [FuzzAction], windows: Int = 1, reportsRemoval: Bool = false) -> InputViolation? {
        InputFuzzer.run(actions, config: InputFuzzer.Config(windows: windows, reportsRemoval: reportsRemoval))?.violation
    }

    // MARK: B1 stale select

    /// A CLI or menu request that names a tab its pane no longer holds (the
    /// tab moved or closed since the snapshot) used to emit `select`, and the
    /// pane showed a tab it does not hold (blank, or stole the view).
    @Test func b1StaleSelectTabNeverSelectsATabThePaneLacks() {
        let (state, effects) = R.run([.selectTab(pane: "a", tab: "t3", source: .cli)], from: R.loaded())
        #expect(!effects.contains(.select(pane: "a", tab: "t3")))
        #expect(state.resolved == .terminal(pane: "a", tab: "t1"))
        #expect(Self.noViolation([.cliSelectTab(window: 0, tab: 2, stalePane: 1)]) == nil)
    }

    @Test func b1SelectInAnotherWorkspaceStillRemembersTheSelection() {
        let effects = R.run([.selectTab(pane: "x", tab: "y", workspace: "other", source: .cli)], from: R.loaded()).1
        #expect(effects.contains(.select(pane: "x", tab: "y")))
    }

    // MARK: B2 active window follows owned key windows

    /// Clicking into a Chromium page window (or a sheet) of another window
    /// left `WindowManager.active` and the published context on the old
    /// window: menu commands and Copy/Paste acted on the old window's terminal.
    @Test func b2PageOrSheetKeyMakesItsWindowActive() {
        #expect(Self.noViolation([.clickPane(window: 1, pane: 0)], windows: 2) == nil)
        #expect(Self.noViolation([.openSheet(window: 0), .clickPane(window: 1, pane: 5), .keyWindow(window: 0)], windows: 3) == nil)
    }

    // MARK: B3 Chromium focus with nothing focused

    /// Switching to an empty workspace left Chromium focus on the old page.
    @Test func b3NoTargetBlursThePage() {
        let actions: [FuzzAction] = [.switchWorkspace(window: 2), .daemonClosePane(pane: 0), .daemonCloseTab(tab: 0), .frame,
                                     .switchWorkspace(window: 2)]
        #expect(Self.noViolation(actions) == nil)
    }

    // MARK: B4 group editor overlay

    /// The tab group editor bubble took the keys without the window's focus
    /// knowing (no overlay), so content shortcuts still targeted the pane.
    @Test func b4GroupEditorIsAnOverlay() {
        #expect(Self.noViolation([.openGroupEditor(window: 0)]) == nil)
    }

    // MARK: B5 palette resign

    /// A click into another window while the palette was open closed it and
    /// then made the palette's parent key again, stealing the click's window.
    @Test func b5ClickOutsideThePaletteKeepsTheClickedWindowKey() {
        #expect(Self.noViolation([.openPalette, .clickPane(window: 1, pane: 0)], windows: 2) == nil)
    }

    // MARK: B6 drag cancel restore

    /// A cancelled drag restored a text-field target the applier cannot put
    /// back (model textField, AppKit on the terminal), a chrome target on a
    /// tab that changed, and clobbered a newer keyboard intent.
    @Test func b6CancelRestoresOnlyWhatCanBeReapplied() {
        let fromField = R.run([.responder(.textField, source: .mouse), .dragBegan(tabs: ["t3"], pane: "c"),
                               .focusPane("c", source: .mouse), .dragEnded(.cancelled)], from: R.loaded()).0
        #expect(fromField.target == .content)

        var topology = R.topology()
        topology.panes[1].tabs.append(R.terminal("b2"))
        var state = R.run([.focusPane("b", source: .mouse), .focusTarget(.findBar, source: .keyboard),
                           .dragBegan(tabs: ["t1"], pane: "a"), .topology(topology)], from: R.loaded()).0
        topology.panes[1].selected = "b2"
        state = R.run([.topology(topology), .dragEnded(.cancelled)], from: state).0
        #expect(state.target == .content)
        #expect(state.resolved == .terminal(pane: "b", tab: "b2"))

        let keyboard = R.run([.dragBegan(tabs: ["t3"], pane: "c"), .focusPane("c", source: .keyboard), .dragEnded(.cancelled)],
                             from: R.loaded()).0
        #expect(keyboard.pane == "c")
        #expect(Self.noViolation([.otherTextField(window: 1), .dragBegin(window: 1), .clickPane(window: 1, pane: 2),
                                  .dragEnd(kind: 0, target: 5)], windows: 3) == nil)
    }

    // MARK: B7 overlay close order

    /// The palette's close reached focus a turn late, so the click that
    /// closed it (into a Chromium page, or the sidebar) was dropped as a
    /// report under an overlay and the window ended with no keyboard target.
    @Test func b7ClickThatClosesThePaletteIsKept() {
        #expect(Self.noViolation([.clickSidebar(window: 0, field: false), .openPalette, .frame, .clickPane(window: 0, pane: 3)]) == nil)
        #expect(Self.noViolation([.openPalette, .clickSidebar(window: 0, field: false)]) == nil)
    }

    // MARK: B9 palette opened while the app is inactive

    /// The palette panel is nonactivating: made key while the app was not
    /// active (a CLI request, a CMUX_NEXT_NO_ACTIVATE=1 run), it took the
    /// system keyboard from the user's frontmost app, and the user's typing
    /// ran palette commands in cmux. It must show without the keys.
    @Test func b9PaletteOpenedWhileInactiveNeverTakesTheKeys() {
        let world = InputWorld(windows: 1, reportsRemoval: false)
        world.perform(.appActive(false))
        world.perform(.openPalette)
        #expect(world.paletteOpen)
        #expect(world.key == .none)
        world.perform(.closePalette)
        #expect(!world.paletteOpen)
        #expect(world.key == .none)
        let v = Self.noViolation([.appActive(false), .openPalette, .frame, .clickPane(window: 0, pane: 0), .closePalette]); #expect(v == nil, "\(String(describing: v))")
    }

    // MARK: F4 chrome target normalization

    /// An expectation or restore could leave `target == .addressBar` on a
    /// terminal tab; the state now never holds a chrome target off a page.
    @Test func f4ChromeTargetOnlyOnAPage() {
        let generation = R.run([.beginIntent], from: R.loaded()).0.generation
        let state = R.run([.beginIntent, .expect(.tab("t3"), target: .addressBar, generation: generation)], from: R.loaded()).0
        #expect(state.target == .content)
        #expect(InputInvariants.model(state).isEmpty)
    }

    // MARK: B8 focus mode on a missing tab

    @Test func b8FocusModeNeverNamesAMissingTab() {
        let state = R.run([.toggleBrowserFocusMode(tab: "gone")], from: R.loaded()).0
        #expect(state.browserFocusMode.isEmpty)
    }

    // MARK: B11 page window takes the keys without a click

    /// User feedback on nxdog9: after opening a browser tab the omnibar lost
    /// the keyboard. A Chromium page window can become key without a click
    /// (Chromium activating the page, AppKit restoring key), also before it
    /// is placed over its pane; then the applier found no pane and did
    /// nothing, and the keys went to the page while the model targeted the
    /// omnibar. The second new tab is a Chromium tab (`DTab.isChromium`).
    @Test func b11UnchosenPageWindowKeyNeverKeepsTheOmnibarKeys() {
        let open: [FuzzAction] = [.userNewTab(window: 0, browser: true), .deliver(0), .deliver(0), .frame]
        for placed in [false, true] {
            let actions = open + open + [.pageTakesKey(window: 0, pane: 0, placed: placed), .type]
            let violation = Self.noViolation(actions)
            #expect(violation == nil, "placed: \(placed): \(String(describing: violation))")
        }
    }
}
