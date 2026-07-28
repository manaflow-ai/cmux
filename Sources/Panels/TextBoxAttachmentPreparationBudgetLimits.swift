struct TextBoxAttachmentPreparationBudgetLimits: Sendable {
    let globalConcurrentCount: Int
    let perComposerConcurrentCount: Int
    let globalReservedBytes: Int
    let perComposerReservedBytes: Int
    let maximumQueuedCount: Int

    static let production = TextBoxAttachmentPreparationBudgetLimits(
        globalConcurrentCount: 4,
        perComposerConcurrentCount: 2,
        globalReservedBytes: 128 * 1024 * 1024,
        perComposerReservedBytes: 64 * 1024 * 1024,
        maximumQueuedCount: 256
    )
}
