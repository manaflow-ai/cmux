/// One stable main-window identity and its current ownership phase.
struct MainWindowLifecycleRecord {
    let order: UInt64
    var phase: MainWindowLifecyclePhase
}
