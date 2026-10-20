extension TerminalFontConfigurationReloadReconciler {
    final class WorkNode {
        let work: ReconciliationWork
        var attemptCount = 0
        var next: WorkNode?

        init(_ work: ReconciliationWork) {
            self.work = work
        }
    }
}
