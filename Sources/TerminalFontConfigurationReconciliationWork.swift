extension TerminalFontConfigurationReloadReconciler {
    struct ReconciliationWork {
        let attempt: @MainActor () -> Bool
        let abandon: Work

        init(
            attempt: @escaping @MainActor () -> Bool,
            abandon: @escaping Work = {}
        ) {
            self.attempt = attempt
            self.abandon = abandon
        }
    }
}
