/// One stable main-window identity and its current ownership phase.
struct MainWindowLifecycleRecord {
    var order: UInt64
    var phase: MainWindowLifecyclePhase
}
