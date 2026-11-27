enum TerminalConfigurationReloadPhase: Equatable {
    case idle
    case waitingForFontWork
    case preparing
    case reconciling
}
