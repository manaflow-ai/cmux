import CmuxSidebarInterpreterClient
import CmuxSidebarRemoteRender
import CmuxSimulator
import CmuxSimulatorWorker
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
        if arguments.contains(SimulatorWorkerClient.workerModeArgument) {
            runSimulatorWorker()
        }
        if arguments.contains(RenderWorkerClient.workerModeArgument) {
            runSidebarRenderWorker()
        }
        if arguments.contains(InterpreterClient.workerModeArgument) {
            runSidebarInterpreterWorker()
            exit(0)
        }
    }
}
