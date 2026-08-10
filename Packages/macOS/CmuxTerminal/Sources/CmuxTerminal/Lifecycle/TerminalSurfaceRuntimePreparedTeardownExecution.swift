/// A native-free Task that cannot run before its coordinator stores the handle.
nonisolated struct TerminalSurfaceRuntimePreparedTeardownExecution: Sendable {
  let task: Task<Void, Never>
  private let startGate: TerminalSurfaceRuntimeTeardownStartGate

  init(
    task: Task<Void, Never>,
    startGate: TerminalSurfaceRuntimeTeardownStartGate
  ) {
    self.task = task
    self.startGate = startGate
  }

  func start() {
    startGate.start()
  }
}
