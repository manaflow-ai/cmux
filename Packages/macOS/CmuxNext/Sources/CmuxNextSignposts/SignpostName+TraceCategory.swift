nonisolated extension SignpostName {
    /// The category whose ``Signposter`` emits this name and whose flag gates its ring records: the
    /// part of the name before the first dot (the catalog test checks the two agree). An inlinable switch,
    /// so a disabled trace point folds it to a constant and reads no `String`.
    @inlinable public var traceCategory: SignpostCategory {
        switch self {
        case .actionPerform, .actionCommit, .actionGate, .actionPresentedEstimate, .actionPresented: .action
        case .motionFrame, .motionRun, .motionDragFrame, .motionLateCommits: .motion
        case .keyToFrame, .keyFlow, .scrollToFrame, .keyOmnibarSuggest, .keyPaletteSearch, .keyEchoHostPTYRead,
             .keyEchoHostClientWrite, .keyEchoDaemonFrames, .keyEchoSurfaceParse, .keyEchoAttachEncode, .keyEchoLineOut,
             .keyEchoAppTransportRead, .keyEchoMainActor, .keyEchoOutputLane, .keyEchoRenderer, .keyEchoGPUDone,
             .keyEchoContents:
            .key
        case .switchWorkspace, .switchTab, .switchPaneFocus, .switchAppActivation: .switch
        case .createTab, .createWorkspace: .create
        case .cefPump, .cefCreateBrowser, .cefGeometry, .cefHostInput, .cefMemoryPressureVote: .cef
        case .launchProcessToMain, .launchFirstWindow, .launchFirstFrame, .launchDaemonReady,
             .launchFirstTerminalOutput, .launchStartupTask, .launchStartupComplete, .launchReadDone,
             .launchActionCatalogFirstMainAccess:
            .launch
        case .stallMainTask, .stallOverBudget, .stallMainTurn, .stallCreateSurface, .stallPaletteOpen, .stallIconPickerOpen,
             .stallRenderStarved, .stallGhosttyRuntimePhase:
            .stall
        case .daemonRequest, .daemonStep: .daemon
        case .frameTick, .frameCommit, .frameGPUDone, .framePresentEstimate, .frameSequence: .frame
        case .taskPost, .taskRun: .task
        case .hangThreadHung, .hangInProgress, .hangInvalidated: .hang
        case .inputFrame, .inputLatency: .input
        case .webviewINP, .webviewLoAF: .webview
        case .remoteInput, .remoteFrameDecoded, .remotePresent: .remote
        case .crashHelperExit, .crashWebContentEnd, .crashRendererUnresponsive, .crashChildExit,
             .crashDumpWithoutCrashing:
            .crash
        case .controlRequest: .control
        case .ghosttyRender: .ghostty
        case .resizeFrame: .resize
        case .webuiLifecycle, .webuiOpen, .webuiPreload, .webuiScheme, .webuiAgentPaneStep: .webui
        case .burstEvent: .burst
        }
    }

    /// ``traceCategory``, as the optional the callers written before it read. Never nil.
    public var category: SignpostCategory? { traceCategory }

    /// The name as a `String`.
    public var description: String { staticName.withUTF8Buffer { String(decoding: $0, as: UTF8.self) } }
}
