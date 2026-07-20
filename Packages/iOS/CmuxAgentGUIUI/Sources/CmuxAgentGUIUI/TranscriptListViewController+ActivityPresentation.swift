#if os(iOS)
extension TranscriptListViewController {
    func applyActivityPresentation(
        onShowActivity: @escaping (TranscriptActivityDetails) -> Void
    ) {
        self.onShowActivity = onShowActivity
    }
}
#endif
