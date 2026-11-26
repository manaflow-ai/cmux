import CmuxSidebarInterpreterClient

// The standalone out-of-process sidebar interpreter worker. The shared loop
// lives in the library so the host app can run the same worker by re-executing
// its own binary (see InterpreterClient.workerModeArgument). Crashing, hanging,
// or exhausting resources here only kills this process; the supervising
// InterpreterClient detects the closed pipe and recovers.
runSidebarInterpreterWorker()
