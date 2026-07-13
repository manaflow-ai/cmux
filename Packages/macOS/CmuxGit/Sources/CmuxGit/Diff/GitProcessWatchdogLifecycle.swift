enum GitProcessWatchdogLifecycle: Int32 {
    case idle
    case terminating
    case armed
    case escalating
    case completedWithoutFire
    case completedAfterFire
    case escalated
}
