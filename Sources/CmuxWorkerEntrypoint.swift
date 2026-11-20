import CmuxSidebarInterpreterClient
import CmuxSidebarRemoteRender
import CmuxSimulator
import CmuxSimulatorWorker
import CmuxSwiftRenderUI
import Darwin

/// Routes a re-executed cmux process into its requested isolated worker mode.
struct CmuxWorkerEntrypoint {
    private let arguments: [String]

    /// Creates a worker router for one process argument snapshot.
    init(arguments: [String]) {
        self.arguments = arguments
    }

    /// Runs the requested worker instead of continuing normal app startup.
    func runIfRequested() {
        if arguments.contains(
            TerminalPastePreparationWorkerClient.workerModeArgument
        ) {
            exit(
                TerminalPastePreparationWorker().run(
                    arguments: arguments
                )
            )
        }
        if arguments.contains(SimulatorWorkerClient.workerModeArgument) {
            runSimulatorWorker()
        }
        if arguments.contains(RenderWorkerClient.workerModeArgument) {
            // The render worker runs JS sidebars too when
            // `customSidebars.renderer` is `remote`.
            JavaScriptCoreProcessOptions.disableConcurrentJIT()
            runSidebarRenderWorker()
        }
        if arguments.contains(InterpreterClient.workerModeArgument) {
            runSidebarInterpreterWorker()
            exit(0)
        }
    }
}
