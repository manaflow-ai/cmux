import CmuxNextSignposts
import CmuxNextTrace
import Testing

/// The frozen p09-observability catalog: ring ids, category bits and the typed trace points.
@Suite("Signpost trace catalog")
struct SignpostTraceCatalogTests {
    @Test("The ids of the names that shipped before the ring never move")
    func shippedIDsArePinned() {
        let pinned: [(SignpostName, UInt16)] = [
            (.actionPerform, 1), (.actionCommit, 2), (.actionGate, 3), (.motionFrame, 4), (.motionRun, 5),
            (.keyToFrame, 6), (.keyFlow, 7), (.scrollToFrame, 8), (.switchWorkspace, 9), (.switchTab, 10),
            (.switchPaneFocus, 11), (.createTab, 12), (.createWorkspace, 13), (.cefPump, 14), (.cefCreateBrowser, 15),
            (.stallMainTask, 16), (.stallOverBudget, 17),
        ]
        for (name, id) in pinned { #expect(name.rawValue == id, "\(name)") }
    }

    @Test("Ring ids are dense from 1 and stay below the interned range")
    func idsAreDense() {
        let ids = SignpostName.allCases.map(\.rawValue).sorted()
        #expect(ids == Array(1...UInt16(ids.count)))
        #expect(ids.allSatisfy { $0 < TraceRuntime.firstInternedID })
    }

    @Test("A name's trace category is the category its string names", arguments: SignpostName.allCases)
    func traceCategoryMatchesThePrefix(_ name: SignpostName) {
        #expect(name.description.hasPrefix(name.traceCategory.rawValue + "."))
        #expect(name.category == name.traceCategory)
        #expect(name.description.utf8.count <= 64)
    }

    @Test("Every category the spec adds has a name, and the 12 echo hops exist")
    func specNamesExist() {
        let names = Set(SignpostName.allCases.map(\.description))
        for required in ["daemon.request", "control.request", "task.post", "task.run", "frame.tick", "frame.commit",
                         "frame.gpu_done", "frame.present_estimate", "frame.sequence", "ghostty.render",
                         "launch.process_to_main", "launch.first_window", "launch.first_frame", "launch.daemon_ready",
                         "launch.first_terminal_output", "stall.create_surface", "stall.palette_open",
                         "stall.icon_picker_open", "cef.geometry", "cef.host_input", "motion.drag_frame",
                         "switch.app_activation", "key.omnibar_suggest", "key.palette_search", "input.frame",
                         "resize.frame", "remote.input", "remote.frame_decoded", "remote.present", "webview.inp",
                         "webview.loaf"] {
            #expect(names.contains(required), "\(required)")
        }
        #expect(names.filter { $0.hasPrefix("key.echo.") }.count == 12)
        #expect(names.contains { $0.hasPrefix("hang.") } && names.contains { $0.hasPrefix("crash.") })
    }

    @Test("Category bits are unique and fit one 64-bit mask")
    func categoryBitsAreUnique() {
        let bits = SignpostCategory.allCases.map(\.traceBit)
        #expect(Set(bits).count == bits.count)
        #expect(bits.allSatisfy { $0 < 64 })
    }

    @Test("The black box records the section 3A default categories")
    func blackBoxDefaults() {
        let on = Set(SignpostCategory.allCases.filter(\.isBlackBoxDefault))
        #expect(on == [.action, .key, .switch, .create, .cef, .launch, .daemon, .hang, .crash])
    }

    @Test("The typed trace points run with their categories off")
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
