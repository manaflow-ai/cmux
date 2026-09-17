internal import CmuxTerminalBackend

@MainActor
protocol BackendOnlyHostRuntimeLifecycle: AnyObject {
    var selection: BackendOnlyTerminalSelection { get }
    func shutdown() async
}
