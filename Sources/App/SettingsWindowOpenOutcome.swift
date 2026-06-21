/// Recovery decision after a settings-window open request reaches its verification deadline.
enum SettingsWindowOpenOutcome: Equatable {
    case materialized
    case retry
    case giveUp
}
