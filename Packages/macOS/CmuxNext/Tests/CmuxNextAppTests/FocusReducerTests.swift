@testable import CmuxNextApp
import Testing

/// Table tests for the focus reducer (plans/cmux-next/focus.md). Each race
/// from the root-cause list (R1-R8) has a named test.
struct FocusReducerTests {
    typealias Pane = FocusTopology.Pane
    typealias Tab = FocusTopology.Tab

    static func terminal(_ id: String) -> Tab { Tab(id: id, surface: "s-\(id)", kind: .terminal) }
    static func browser(_ id: String) -> Tab { Tab(id: id, surface: "s-\(id)", kind: .browser) }

    /// Workspace `w` with panes a (t1, t2), b (b1 browser), c (t3).
    static func topology(workspace: String = "w") -> FocusTopology {
        FocusTopology(workspace: workspace, panes: [
            Pane(id: "a", tabs: [terminal("t1"), terminal("t2")], selected: "t1"),
            Pane(id: "b", tabs: [browser("b1")], selected: "b1"),
            Pane(id: "c", tabs: [terminal("t3")], selected: "t3"),
        ])
    }

    static func run(_ events: [FocusEvent], from start: FocusState = FocusState()) -> (FocusState, [FocusEffect]) {
        var state = start
        var effects: [FocusEffect] = []
        for event in events {
            let (next, produced) = FocusReducer.reduce(state, event)
            state = next
            effects = produced
        }
        return (state, effects)
    }

    static func loaded() -> FocusState { run([.windowKey(true), .topology(topology())]).0 }

    // MARK: Placement

    @Test func initialPlacementFocusesTheFirstPaneAndMovesTheResponder() {
        let (state, effects) = Self.run([.topology(Self.topology())])
        #expect(state.resolved == .terminal(pane: "a", tab: "t1"))
        #expect(effects.contains(.moveResponder(.terminal(pane: "a", tab: "t1"))))
        #expect(effects.contains(.revealPane("a")))
        #expect(effects.contains(.publishContext(FocusState.Context(terminal: true))))
    }

    @Test func workspaceSwitchRestoresTheRememberedPane() {
        var state = Self.run([.focusPane("c", source: .mouse)], from: Self.loaded()).0
        state = Self.run([.topology(Self.topology(workspace: "other"))], from: state).0
        #expect(state.pane == "a")
        state = Self.run([.topology(Self.topology(workspace: "w"))], from: state).0
        #expect(state.resolved == .terminal(pane: "c", tab: "t3"))
    }

    @Test func cliFocusForAnotherWorkspaceAppliesWhenItShows() {
        var state = Self.run([.focusPane("c", workspace: "later", source: .cli)], from: Self.loaded()).0
        #expect(state.pane == "a")
        state = Self.run([.topology(Self.topology(workspace: "later"))], from: state).0
        #expect(state.pane == "c")
    }

    @Test func sidebarKeyboardNavigationKeepsTheSidebarAcrossWorkspaceSwitch() {
        var state = Self.run([.responder(.sidebar, source: .keyboard)], from: Self.loaded()).0
        state = Self.run([.topology(Self.topology(workspace: "next"))], from: state).0
        #expect(state.resolved == .sidebar)
    }

    @Test func sidebarClickThenWorkspaceSwitchFocusesContent() {
        var state = Self.run([.responder(.sidebar, source: .mouse)], from: Self.loaded()).0
        let (next, effects) = Self.run([.topology(Self.topology(workspace: "next"))], from: state)
        state = next
        #expect(state.resolved == .terminal(pane: "a", tab: "t1"))
        #expect(effects.contains(.moveResponder(.terminal(pane: "a", tab: "t1"))))
    }

    // MARK: R1: selection changes the responder must follow

    @Test func closingTheSelectedTabMovesFocusToTheNewSelection() {
        var topology = Self.topology()
        topology.panes[0] = Pane(id: "a", tabs: [Self.terminal("t2")], selected: "t2")
        let (state, effects) = Self.run([.topology(topology)], from: Self.loaded())
        #expect(state.resolved == .terminal(pane: "a", tab: "t2"))
        #expect(effects.contains(.moveResponder(.terminal(pane: "a", tab: "t2"))))
    }

    @Test func contentPresentedReappliesOnlyForTheFocusedPane() {
        #expect(Self.run([.contentPresented(pane: "a")], from: Self.loaded()).1.contains(.moveResponder(.terminal(pane: "a", tab: "t1"))))
        #expect(Self.run([.contentPresented(pane: "b")], from: Self.loaded()).1.isEmpty)
    }

    @Test func responderLostToTheWindowIsRepairedNotAccepted() {
        let (state, effects) = Self.run([.responder(.windowOrNone, source: .programmatic)], from: Self.loaded())
        #expect(state.resolved == .terminal(pane: "a", tab: "t1"))
        #expect(effects.contains(.moveResponder(.terminal(pane: "a", tab: "t1"))))
    }

    // MARK: R2: removed pane successor

    @Test func removedFocusedPaneReturnsToThePreviouslyFocusedPane() {
        var state = Self.run([.focusPane("c", source: .mouse), .focusPane("b", source: .mouse)], from: Self.loaded()).0
        var topology = Self.topology()
        topology.panes.remove(at: 1)
        state = Self.run([.topology(topology)], from: state).0
        #expect(state.pane == "c")
    }

    @Test func removedFocusedPaneWithoutHistoryFallsToTheNextSurvivingPane() {
        var state = Self.loaded()
        state.history = []
        var topology = Self.topology()
        topology.panes.removeFirst()
        state = Self.run([.topology(topology)], from: state).0
        #expect(state.pane == "b")
    }

    @Test func removedLastPaneWithoutHistoryFallsToThePreviousPane() {
        var state = Self.run([.focusPane("c", source: .mouse)], from: Self.loaded()).0
        state.history = ["c"]
        var topology = Self.topology()
        topology.panes.removeLast()
        state = Self.run([.topology(topology)], from: state).0
        #expect(state.pane == "b")
        #expect(state.resolved == .browserPage(pane: "b", tab: "b1"))
    }

    @Test func removedPaneDropsAddressBarTarget() {
        var state = Self.run([.focusPane("b", source: .mouse), .focusTarget(.addressBar, source: .keyboard)], from: Self.loaded()).0
        #expect(state.resolved == .addressBar(pane: "b", tab: "b1"))
        var topology = Self.topology()
        topology.panes.remove(at: 1)
        state = Self.run([.topology(topology)], from: state).0
        #expect(state.resolved == .terminal(pane: "a", tab: "t1"))
    }

    // MARK: R3: responders outside panes

    @Test func sidebarFieldClearsContentContext() {
        let (state, effects) = Self.run([.responder(.sidebarField, source: .mouse)], from: Self.loaded())
        #expect(state.context == FocusState.Context())
        #expect(state.resolved.isTextInput)
        #expect(effects.contains(.publishContext(FocusState.Context())))
    }

    @Test func clickInAnotherPaneIsAcceptedWithoutMovingTheResponderAgain() {
        let (state, effects) = Self.run([.responder(.content(pane: "c"), source: .mouse)], from: Self.loaded())
        #expect(state.pane == "c")
        #expect(effects.contains(.revealPane("c")))
    }

    @Test func sidebarRenameEndedByKeyboardReturnsToTheContent() {
        let state = Self.run([.focusPane("c", source: .mouse), .responder(.sidebarField, source: .mouse),
                              .responder(.sidebar, source: .keyboard), .focusTarget(.content, source: .keyboard)], from: Self.loaded()).0
        #expect(state.resolved == .terminal(pane: "c", tab: "t3"))
        #expect(state.context == FocusState.Context(terminal: true))
    }

    @Test func responderReportsAreIgnoredWhileAnOverlayIsOpen() {
        let state = Self.run([.overlayOpened(.rename), .responder(.sidebarField, source: .keyboard)], from: Self.loaded()).0
        #expect(state.target == .content)
        #expect(state.resolved == .overlay(.rename))
    }

    // MARK: R4 and R6: intents and expectations

    @Test func selectTabFocusesItsPaneAndEmitsSelect() {
        let (state, effects) = Self.run([.selectTab(pane: "a", tab: "t2", source: .mouse)], from: Self.loaded())
        #expect(state.resolved == .terminal(pane: "a", tab: "t2"))
        #expect(effects.contains(.select(pane: "a", tab: "t2")))
    }

    @Test func expectationLandsWhenTheSurfaceAppears() {
        var state = Self.loaded()
        state = Self.run([.expect(.surface("s-new"), target: .content, generation: state.generation)], from: state).0
        var topology = Self.topology()
        topology.panes.append(Pane(id: "d", tabs: [Self.terminal("new")], selected: "new"))
        let (next, effects) = Self.run([.topology(topology)], from: state)
        #expect(next.resolved == .terminal(pane: "d", tab: "new"))
        #expect(next.expectation == nil)
        #expect(effects.contains(.select(pane: "d", tab: "new")))
    }

    @Test func expectationIsDroppedAfterANewerUserIntent() {
        var state = Self.loaded()
        let generation = Self.run([.beginIntent], from: state).0.generation
        state = Self.run([.beginIntent, .focusPane("c", source: .mouse),
                          .expect(.surface("s-new"), target: .content, generation: generation)], from: state).0
        #expect(state.expectation == nil)
        var topology = Self.topology()
        topology.panes.append(Pane(id: "d", tabs: [Self.terminal("new")], selected: "new"))
        state = Self.run([.topology(topology)], from: state).0
        #expect(state.pane == "c")
    }

    @Test func pendingExpectationIsDroppedByAClickBeforeItLands() {
        var state = Self.loaded()
        state = Self.run([.expect(.surface("s-new"), target: .content, generation: state.generation),
                          .responder(.content(pane: "b"), source: .mouse)], from: state).0
        var topology = Self.topology()
        topology.panes.append(Pane(id: "d", tabs: [Self.terminal("new")], selected: "new"))
        state = Self.run([.topology(topology)], from: state).0
        #expect(state.pane == "b")
    }

    @Test func newBrowserExpectationFocusesItsAddressBar() {
        var state = Self.loaded()
        state = Self.run([.expect(.surface("s-web"), target: .addressBar, generation: state.generation)], from: state).0
        var topology = Self.topology()
        topology.panes[0].tabs.append(Self.browser("web"))
        state = Self.run([.topology(topology)], from: state).0
        #expect(state.resolved == .addressBar(pane: "a", tab: "web"))
    }

    @Test func addressBarRequiresABrowserTab() {
        let state = Self.run([.focusTarget(.addressBar, source: .keyboard)], from: Self.loaded()).0
        #expect(state.resolved == .terminal(pane: "a", tab: "t1"))
    }

    // MARK: R7: drag

    @Test func droppedTabIsSelectedAndFocusedInItsNewPane() {
        var state = Self.run([.dragBegan(tabs: ["t2"], pane: "a")], from: Self.loaded()).0
        var topology = Self.topology()
        topology.panes[0].tabs.removeLast()
        topology.panes[2].tabs.append(Self.terminal("t2"))
        state = Self.run([.topology(topology)], from: state).0
        let (next, effects) = Self.run([.dragEnded(.dropped(tabs: ["t2"]))], from: state)
        #expect(next.resolved == .terminal(pane: "c", tab: "t2"))
        #expect(effects.contains(.select(pane: "c", tab: "t2")))
        #expect(next.drag == nil)
    }

    @Test func dropIntoANewSplitFocusesItWhenThePaneLands() {
        var state = Self.run([.dragBegan(tabs: ["t2"], pane: "a"), .dragEnded(.dropped(tabs: ["t2"], awayFrom: "a"))], from: Self.loaded()).0
        #expect(state.expectation?.key == .tab("t2"))
        var topology = Self.topology()
        topology.panes[0].tabs.removeLast()
        topology.panes.insert(Pane(id: "split", tabs: [Self.terminal("t2")], selected: "t2"), at: 1)
        state = Self.run([.topology(topology)], from: state).0
        #expect(state.resolved == .terminal(pane: "split", tab: "t2"))
    }

    @Test func reorderInPlaceFocusesTheDroppedTabAtOnce() {
        let (state, effects) = Self.run([.dragBegan(tabs: ["t2"], pane: "a"), .dragEnded(.dropped(tabs: ["t2"]))], from: Self.loaded())
        #expect(state.resolved == .terminal(pane: "a", tab: "t2"))
        #expect(effects.contains(.select(pane: "a", tab: "t2")))
    }

    @Test func dragWhoseSourcePaneEmptiesNeverTargetsTheRemovedPane() {
        var state = Self.run([.focusPane("c", source: .mouse), .dragBegan(tabs: ["t3"], pane: "c")], from: Self.loaded()).0
        var topology = Self.topology()
        topology.panes.removeLast()
        topology.panes[0].tabs.append(Self.terminal("t3"))
        state = Self.run([.topology(topology), .dragEnded(.dropped(tabs: ["t3"]))], from: state).0
        #expect(state.resolved == .terminal(pane: "a", tab: "t3"))
    }

    @Test func cancelledDragRestoresFocus() {
        let state = Self.run([.dragBegan(tabs: ["t3"], pane: "c"), .responder(.content(pane: "c"), source: .mouse),
                              .dragEnded(.cancelled)], from: Self.loaded()).0
        #expect(state.pane == "a")
    }

    @Test func tabMovedToAnotherWindowRepairsTheSourceWindow() {
        var state = Self.run([.dragBegan(tabs: ["t1"], pane: "a")], from: Self.loaded()).0
        var topology = Self.topology()
        topology.panes[0] = Pane(id: "a", tabs: [Self.terminal("t2")], selected: "t2")
        state = Self.run([.topology(topology), .dragEnded(.movedAway)], from: state).0
        #expect(state.resolved == .terminal(pane: "a", tab: "t2"))
        #expect(state.drag == nil)
    }

    // MARK: R8: overlays

    @Test func overlayPushPopRestoresTheLiveTarget() {
        var (state, _) = Self.run([.overlayOpened(.palette)], from: Self.loaded())
        #expect(state.resolved == .overlay(.palette))
        // Palette commands act on the content below it.
        #expect(state.context == FocusState.Context(terminal: true))
        #expect(Self.run([.overlayOpened(.sheet)], from: Self.loaded()).0.context == FocusState.Context())
        state = Self.run([.focusPane("c", source: .palette)], from: state).0
        let (next, effects) = Self.run([.overlayClosed(.palette)], from: state)
        #expect(next.resolved == .terminal(pane: "c", tab: "t3"))
        #expect(effects.contains(.moveResponder(.terminal(pane: "c", tab: "t3"))))
    }

    @Test func nestedOverlaysPopInOrder() {
        let state = Self.run([.overlayOpened(.palette), .overlayOpened(.sheet), .overlayClosed(.sheet)], from: Self.loaded()).0
        #expect(state.resolved == .overlay(.palette))
    }

    // MARK: Browser focus mode

    @Test func browserFocusModeTogglesForTheFocusedPageAndEndsWithTheTab() {
        var state = Self.run([.focusPane("b", source: .mouse), .toggleBrowserFocusMode(tab: nil)], from: Self.loaded()).0
        #expect(state.isBrowserFocusModeActive)
        var topology = Self.topology()
        topology.panes.remove(at: 1)
        let (next, effects) = Self.run([.topology(topology)], from: state)
        state = next
        #expect(state.browserFocusMode.isEmpty)
        #expect(effects.contains(.browserFocusMode(tab: "b1", active: false)))
    }

    @Test func browserFocusModeNeedsABrowserTab() {
        let state = Self.run([.toggleBrowserFocusMode(tab: nil)], from: Self.loaded()).0
        #expect(state.browserFocusMode.isEmpty)
    }

    // MARK: Window key

    @Test func becomingKeyReassertsResponderAndContext() {
        let (_, effects) = Self.run([.windowKey(false), .windowKey(true)], from: Self.loaded())
        #expect(effects.contains(.moveResponder(.terminal(pane: "a", tab: "t1"))))
        #expect(effects.contains(.publishContext(FocusState.Context(terminal: true))))
    }
}
