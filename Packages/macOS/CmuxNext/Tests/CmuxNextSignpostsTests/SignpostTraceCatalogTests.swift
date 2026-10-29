import CmuxNextSignposts
@testable import CmuxNextTrace
import Testing

/// The frozen p09-observability catalog: ring ids, category bits and the typed trace points.
@Suite("Signpost trace catalog")
struct SignpostTraceCatalogTests {
    /// Every ring id, pinned: a ring names its records by these numbers, so a swap of two ids decodes an
    /// older ring wrong. Ids 1-17 shipped before the ring. Append a new name with the next id; never edit
    /// a pair here.
    @Test("Every catalog name keeps its ring id")
    func everyIDIsPinned() {
        let pinned: [(SignpostName, UInt16)] = [
            (.actionPerform, 1), (.actionCommit, 2), (.actionGate, 3), (.motionFrame, 4), (.motionRun, 5),
            (.keyToFrame, 6), (.keyFlow, 7), (.scrollToFrame, 8), (.switchWorkspace, 9), (.switchTab, 10),
            (.switchPaneFocus, 11), (.createTab, 12), (.createWorkspace, 13), (.cefPump, 14), (.cefCreateBrowser, 15),
            (.stallMainTask, 16), (.stallOverBudget, 17), (.motionDragFrame, 18), (.keyOmnibarSuggest, 19),
            (.keyPaletteSearch, 20), (.keyEchoHostPTYRead, 21), (.keyEchoHostClientWrite, 22), (.keyEchoDaemonFrames, 23),
            (.keyEchoSurfaceParse, 24), (.keyEchoAttachEncode, 25), (.keyEchoLineOut, 26), (.keyEchoAppTransportRead, 27),
            (.keyEchoMainActor, 28), (.keyEchoOutputLane, 29), (.keyEchoRenderer, 30), (.keyEchoGPUDone, 31),
            (.keyEchoContents, 32), (.switchAppActivation, 33), (.cefGeometry, 34), (.cefHostInput, 35),
            (.launchProcessToMain, 36), (.launchFirstWindow, 37), (.launchFirstFrame, 38), (.launchDaemonReady, 39),
            (.launchFirstTerminalOutput, 40), (.stallCreateSurface, 41), (.stallPaletteOpen, 42),
            (.stallIconPickerOpen, 43), (.daemonRequest, 44), (.frameTick, 45), (.frameCommit, 46), (.frameGPUDone, 47),
            (.framePresentEstimate, 48), (.frameSequence, 49), (.taskPost, 50), (.taskRun, 51), (.hangThreadHung, 52),
            (.hangInProgress, 53), (.hangInvalidated, 54), (.inputFrame, 55), (.webviewINP, 56), (.webviewLoAF, 57),
            (.remoteInput, 58), (.remoteFrameDecoded, 59), (.remotePresent, 60), (.crashHelperExit, 61),
            (.crashWebContentEnd, 62), (.crashRendererUnresponsive, 63), (.crashChildExit, 64),
            (.crashDumpWithoutCrashing, 65), (.controlRequest, 66), (.ghosttyRender, 67), (.resizeFrame, 68),
            (.webuiLifecycle, 69), (.webuiOpen, 70), (.webuiPreload, 71), (.webuiScheme, 72), (.stallMainTurn, 73),
            (.stallRenderStarved, 74), (.launchStartupTask, 75), (.launchStartupComplete, 76), (.daemonStep, 77),
            (.webuiAgentPaneStep, 78), (.stallGhosttyRuntimePhase, 79), (.launchReadDone, 80), (.burstEvent, 81),
            (.motionLateCommits, 82), (.actionPresentedEstimate, 83), (.actionPresented, 84),
            (.inputLatency, 85),
            (.cefMemoryPressureVote, 86),
            (.ghosttyLockWait, 87),
            (.launchActionCatalogFirstMainAccess, 88),
        ]
        for (name, id) in pinned { #expect(name.rawValue == id, "\(name)") }
        #expect(SignpostName.allCases.count == pinned.count)
    }

    /// trace.md "Name table": the ring's creator writes entry 0 (empty), the catalog names and one entry
    /// per category, and interned names follow from `name_cursor`. All of them fit the smallest role's
    /// `name_capacity` (the terminal host's 1024, trace.md "Sizes by role") with room left to intern.
    @Test("Ring ids are dense from 1 and the catalog fits every role's name table")
    func idsAreDense() {
        let ids = SignpostName.allCases.map(\.rawValue).sorted()
        #expect(ids == Array(1...UInt16(ids.count)))
        let smallestNameCapacity = 1024
        #expect(1 + ids.count + SignpostCategory.allCases.count < smallestNameCapacity / 2)
    }

    @Test("A name's trace category is the category its string names", arguments: SignpostName.allCases)
    func traceCategoryMatchesThePrefix(_ name: SignpostName) {
        #expect(name.description.hasPrefix(name.traceCategory.rawValue + "."))
        #expect(name.category == name.traceCategory)
        #expect(name.description.utf8.count <= 55)
    }

    @Test("Every category the spec adds has a name, and the 12 echo hops exist")
    func specNamesExist() {
        let names = Set(SignpostName.allCases.map(\.description))
        for required in ["daemon.request", "control.request", "task.post", "task.run", "frame.tick", "frame.commit",
                         "frame.gpu_done", "frame.present_estimate", "frame.sequence", "ghostty.render",
                         "launch.process_to_main", "launch.first_window", "launch.first_frame", "launch.daemon_ready",
                         "launch.first_terminal_output", "stall.create_surface", "stall.palette_open",
                         "stall.icon_picker_open", "cef.geometry", "cef.host_input", "motion.drag_frame",
                         "switch.app_activation", "key.omnibar_suggest", "key.palette_search", "input.frame", "input.latency",
                         "resize.frame", "remote.input", "remote.frame_decoded", "remote.present", "webview.inp",
                         "webview.loaf", "webui.lifecycle", "webui.open", "webui.preload", "webui.scheme",
                         "motion.late_commits", "action.presented_estimate", "action.presented"] {
            #expect(names.contains(required), "\(required)")
        }
        #expect(names.filter { $0.hasPrefix("key.echo.") }.count == 12)
        #expect(names.contains { $0.hasPrefix("hang.") } && names.contains { $0.hasPrefix("crash.") })
    }

    /// trace.md "Release trace ring: category bits". Rust's `cmux-trace/tests/shared_values.rs` pins the
    /// same numbers, so the app and the daemon turn on and label the same categories.
    @Test("Every category keeps its shared trace bit")
    func categoryBitsArePinned() {
        let pinned: [(SignpostCategory, UInt8)] = [
            (.action, 0), (.key, 1), (.switch, 2), (.create, 3), (.cef, 4), (.launch, 5), (.daemon, 6), (.hang, 7),
            (.crash, 8), (.motion, 9), (.frame, 10), (.stall, 11), (.task, 12), (.burst, 13), (.input, 14),
            (.webview, 15), (.remote, 16), (.control, 17), (.ghostty, 18), (.resize, 19), (.webui, 20),
            (.log, 21),
        ]
        for (category, bit) in pinned { #expect(category.traceBit == bit, "\(category)") }
        #expect(SignpostCategory.allCases.count == pinned.count)
    }

    @Test("The black box records the section 3A default categories, bits 0-8")
    func blackBoxDefaults() {
        let on = SignpostCategory.allCases.filter(\.isBlackBoxDefault)
        #expect(Set(on) == [.action, .key, .switch, .create, .cef, .launch, .daemon, .hang, .crash])
        #expect(Set(on.map(\.traceBit)) == Set(0...8))
    }

    @Test("The webui names record under the webui bit only, outside the black box and MetricKit")
    func webuiNamesGateOnTheirBit() {
        // webui.agent_pane_step is an agent page's step: it fires per tab, so it is a webui name, not a launch one.
        let webui: [SignpostName] = [.webuiLifecycle, .webuiOpen, .webuiPreload, .webuiScheme, .webuiAgentPaneStep]
        #expect(SignpostName.allCases.filter { $0.traceCategory == .webui } == webui)
        #expect(!SignpostCategory.webui.isBlackBoxDefault)
        #expect(!webui.contains(where: SignpostMetricKitMirror.mirrors))
        let runtime = TraceRuntime(role: .app)
        func recorded() -> UInt64 { runtime.stubRecordCount.load(ordering: .relaxed) }
        runtime.setCategoryMask(1 << UInt64(SignpostCategory.webview.traceBit))
        runtime.asyncBegin(.webuiOpen, id: 1, arg0: 1)
        runtime.begin(.webuiScheme, arg0: 0)
        #expect(recorded() == 0)
        runtime.setCategoryMask(1 << UInt64(SignpostCategory.webui.traceBit))
        runtime.asyncBegin(.webuiOpen, id: 1, arg0: 1)
        runtime.asyncEnd(.webuiOpen, id: 1)
        runtime.begin(.webuiScheme, arg0: 1)
        runtime.end(.webuiScheme, arg0: 0, arg1: 512)
        runtime.event(.webuiLifecycle, arg0: 1, arg1: 2)
        runtime.event(.webuiPreload, arg0: 1, arg1: 0)
        #expect(recorded() == 6)
    }

    @Test("A typed trace point records only while its name's category is on")
    func typedTracePointsGateOnTheirCategory() {
        let runtime = TraceRuntime(role: .app)
        func recorded() -> UInt64 { runtime.stubRecordCount.load(ordering: .relaxed) }
        runtime.begin(.cefPump, arg0: 1)
        runtime.end(.cefPump, arg0: 0, arg1: 250)
        runtime.asyncBegin(.createTab, id: 7)
        runtime.asyncEnd(.createTab, id: 7)
        runtime.event(.framePresentEstimate, arg0: 42, arg1: 1_000, estimated: true)
        runtime.flowOut(.keyEchoLineOut, flow: 42)
        runtime.flowIn(.keyEchoAppTransportRead, flow: 42)
        runtime.counter(.frameSequence, value: 3)
        #expect(runtime.interval(.taskRun, arg0: 0) { 5 } == 5)
        #expect(recorded() == 0)
        runtime.setCategoryMask(1 << UInt64(SignpostCategory.cef.traceBit))
        runtime.begin(.cefPump, arg0: 1)
        runtime.end(.cefPump, arg0: 0)
        runtime.asyncBegin(.createTab, id: 8)
        runtime.flowOut(.keyEchoLineOut, flow: 43)
        #expect(recorded() == 2)
    }

    @Test("The static trace points run against the process runtime")
    func typedTracePointsRun() {
        Signposter.begin(.cefPump, arg0: 1)
        Signposter.end(.cefPump, arg0: 0, arg1: 250)
        Signposter.asyncBegin(.createTab, id: 7, arg0: 0)
        Signposter.asyncEnd(.createTab, id: 7)
        Signposter.event(.framePresentEstimate, arg0: 42, arg1: 1_000, estimated: true)
        Signposter.flowOut(.keyEchoLineOut, flow: 42)
        Signposter.flowIn(.keyEchoAppTransportRead, flow: 42)
        Signposter.counter(.frameSequence, value: 3)
        #expect(Signposter.interval(.taskRun, arg0: 0) { 5 } == 5)
    }
}
