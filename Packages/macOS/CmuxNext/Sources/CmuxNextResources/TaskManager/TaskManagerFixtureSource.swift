import Foundation

/// Another source's samples with fixed discarded items: the `task-manager` capture scene shows the
/// app's real processes and two pages Memory Saver discarded, one with the memory it saved and
/// one discarded with no measurement.
public final class TaskManagerFixtureSource: TaskManagerSampleSource {
    /// The scene's discarded pages.
    public static let captureDiscarded = [
        TaskManagerDiscardedItem(id: "capture-discarded-docs", title: "Design review notes", savedBytes: 182 << 20),
        TaskManagerDiscardedItem(id: "capture-discarded-news", title: "Release status", savedBytes: nil),
    ]

    public let discarded: [TaskManagerDiscardedItem]
    private let base: any TaskManagerSampleSource

    /// - Parameters:
    ///   - base: Takes the real sample; held strongly (the fixture is the model's only source).
    ///   - discarded: The discarded items every sample lists, in place of the base's.
    public init(base: any TaskManagerSampleSource,
                discarded: [TaskManagerDiscardedItem] = TaskManagerFixtureSource.captureDiscarded) {
        self.base = base
        self.discarded = discarded
    }

    @MainActor public func sample() async -> TaskManagerSampleSet {
        var set = await base.sample()
        set.discarded = discarded
        return set
    }
}
