import CmuxNextSettings
import CmuxNextSignposts

/// What a build can be measured with: the answer of `debug.capabilities` (Debug and bench builds).
///
/// The perf lab runs today's harness against old builds (a bisect midpoint, the weekly reference). A story
/// declares the capabilities it reads (`needs` in scripts/perf-lab/stories.d), and a build that lacks one is
/// not-measurable, never a regression (scripts/perf-lab/capabilities.py). Telemetry asks the same of the
/// browser under test before it runs a story (`CanRunOnBrowser`, third_party/catapult/telemetry/telemetry/
/// page/shared_page_state.py) and records a story that cannot run as skipped, not failed.
///
/// - `methods`: the `debug.*` control methods registered when it is asked, so every group the App registers.
/// - `signposts`: the names of ``emittedSignposts``, the ``SignpostName`` cases this build has an emitter
///   for (a reserved case has none, so no bench may read it).
/// - `environment`: ``probeEnvironment``, the launch variables that turn on a probe a bench reads.
///
/// The method takes no params and changes no state.
///
/// ```swift
/// DebugCapabilities(methods: ["debug.hangs"]).json
/// // {"schema": "cmux-debug-capabilities/v1", "methods": ["debug.hangs"], "signposts": [...], "environment": [...]}
/// ```
struct DebugCapabilities: Sendable, Equatable {
    static let method = "debug.capabilities"
    static let schema = "cmux-debug-capabilities/v1"

    /// The cases with an emitter in this build. capabilities.py `--check` proves each one has an emit site,
    /// so add a case here in the change that adds its emitter.
    static let emittedSignposts: [SignpostName] = [
        .actionPerform, .actionCommit, .actionGate, .actionPresentedEstimate,
        .motionFrame, .motionRun, .motionDragFrame, .motionLateCommits,
        .keyToFrame, .keyFlow, .scrollToFrame, .keyOmnibarSuggest, .keyPaletteSearch,
        .switchWorkspace, .switchTab, .switchPaneFocus, .switchAppActivation,
        .createTab, .createWorkspace,
        .cefPump, .cefCreateBrowser, .cefGeometry, .cefHostInput, .cefMemoryPressureVote,
        .stallMainTask, .stallOverBudget, .stallPaletteOpen, .stallIconPickerOpen, .stallRenderStarved,
        .stallMainTurn, .stallCreateSurface, .stallGhosttyRuntimePhase,
        .launchStartupTask, .launchStartupComplete, .launchReadDone,
        .daemonRequest, .daemonStep,
        .frameTick, .frameCommit, .frameGPUDone, .framePresentEstimate, .frameSequence,
        .taskRun, .hangThreadHung, .inputLatency, .ghosttyRender,
        .webuiOpen, .webuiScheme, .webuiPreload, .webuiAgentPaneStep,
        .burstEvent,
    ]

    /// The probe launch variables a bench may set. capabilities.py `--check` proves each one is read by a
    /// source other than this file.
    static let probeEnvironment: [String] = [
        "CMUX_NEXT_CLASSIC_HOME",
        "CMUX_NEXT_DEBUG_TUNABLES_FILE",
        "CMUX_NEXT_HANG_THRESHOLD_MS",
        "CMUX_NEXT_TRACE_FLOWS",
        "CMUX_NEXT_TUI_DEBUG_SPANS",
        "CMUX_NEXT_TUI_TERMINAL_HOST_MODEL",
        "CMUX_NEXT_TYPING_PROBE",
    ]

    let methods: [String]
    let signposts: [String]
    let environment: [String]

    /// - Parameters:
    ///   - methods: Registered method names; only the `debug.*` ones are kept, sorted.
    ///   - signposts: The emitted cases (``emittedSignposts`` by default).
    ///   - environment: The probe variables (``probeEnvironment`` by default).
    init(methods: some Sequence<String>, signposts: [SignpostName] = DebugCapabilities.emittedSignposts,
         environment: [String] = DebugCapabilities.probeEnvironment) {
        self.methods = Set(methods.filter(ControlRouter.isDebugMethod)).sorted()
        self.signposts = Set(signposts.map(\.description)).sorted()
        self.environment = Set(environment).sorted()
    }

    var json: JSONValue {
        [
            "schema": .string(Self.schema),
            "methods": .array(methods.map(JSONValue.string)),
            "signposts": .array(signposts.map(JSONValue.string)),
            "environment": .array(environment.map(JSONValue.string)),
        ]
    }
}

extension ControlRouter {
    /// `debug.capabilities`: answered off the main actor from the router's registered names, so it works
    /// while the main thread is stalled. A release router drops it with every other `debug.*` method.
    func capabilitiesMethods() -> [ControlMethod] {
        [
            .snapshot(DebugCapabilities.method) { [weak self] call in
                guard let self else { throw Self.stopped }
                if let unknown = call.params.keys.sorted().first {
                    throw ControlError.invalidParams(ControlStrings.format("control.error.unknownParam", "%1$@ does not take params.%2$@",
                                                                           DebugCapabilities.method, unknown))
                }
                return DebugCapabilities(methods: self.methodNames).json
            }.readingLastPublished(),
        ]
    }
}
