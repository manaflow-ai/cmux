public import Foundation

/// RED STUB (R96 quit hook): the store API with no behavior yet.
@MainActor
public final class RecoveryDraftStore {
    public static let shared = RecoveryDraftStore(directory: RecoveryDraftFiles.defaultDirectory)
    public static let defaultMaxDraftBytes = 8 * 1024 * 1024
    public static let defaultMaxTotalBytes = 100 * 1024 * 1024
    public let directory: URL
    public var restoreHandler: ((RecoveryDraft) -> Void)?

    public init(directory: URL, clock: any Clock<Duration> = ContinuousClock(), debounce: Duration = .seconds(1),
                maxDraftBytes: Int = RecoveryDraftStore.defaultMaxDraftBytes,
                maxTotalBytes: Int = RecoveryDraftStore.defaultMaxTotalBytes) {
        self.directory = directory
    }

    @discardableResult
    public func update(id: String, title: String, contents: Data, host: String = "local",
                       filePath: String? = nil) -> RecoveryDraftAcceptance { .kept }
    public func remove(id: String) async {}
    public func writePending() async {}
    public func drafts() async -> [RecoveryDraft] { [] }
    public func fileChangedSince(_ draft: RecoveryDraft) async -> Bool { false }
}

nonisolated enum RecoveryDraftFiles {
    static var defaultDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/cmux/recovery")
    }
}
