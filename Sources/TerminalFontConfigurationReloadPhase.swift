extension TerminalFontConfigurationReloadReconciler {
    enum Phase {
        case idle
        case capturing
        case reconciling
    }
}
