public import CmuxHomeCore
public import CmuxNextHome

/// The settings card of a bare launch's Chief page (`HomeLaunchComposer`) before the Chief's
/// owner answers. It shows no engine that could change at the handover: its read waits for the
/// real Chief and reads that one. A change the person makes there (model, effort, harness)
/// waits for the real Chief too and is then made on it, never dropped on the provisional one.
/// A page that went or quit first refuses both.
public nonisolated struct HomeLaunchChiefEngine: HomeChiefEngineSource {
    /// The card's source for the provisional Chief (its kind only: this Mac's, a server's).
    let provisional: any HomeChiefEngineSource
    /// The real Chief's source once it is named; nil when the page went before.
    let chief: @MainActor @Sendable () async -> (any HomeChiefEngineSource)?

    /// - Parameters:
    ///   - provisional: The source the card would have for the provisional Chief.
    ///   - chief: Waits for the real Chief (`LaunchChiefHold.resolved()`) and makes its source.
    public init(provisional: any HomeChiefEngineSource, chief: @escaping @MainActor @Sendable () async -> (any HomeChiefEngineSource)?) {
        self.provisional = provisional
        self.chief = chief
    }

    public var isLocal: Bool { provisional.isLocal }
    public var place: String? { provisional.place }
    public var choosesHarness: Bool { provisional.choosesHarness }

    /// The real Chief's engine, once it is named (waits until then).
    public func read() async throws(HomeChiefEngineError) -> HomeChiefSnapshot {
        try await real().read()
    }

    /// Made on the real Chief once it is named (waits until then).
    public func set(_ fields: [String: String?]) async throws(HomeChiefEngineError) -> HomeChiefSnapshot {
        try await real().set(fields)
    }

    private func real() async throws(HomeChiefEngineError) -> any HomeChiefEngineSource {
        guard let real = await chief() else { throw provisional.isLocal ? .localUnreachable : .cloudUnreachable }
        return real
    }

    /// The card's source for conversation `id`: `own` itself, unless `id` is a bare launch's
    /// provisional Chief (`HomeLaunchChiefSource.conversation`) with a page holding its sends;
    /// then it waits for the real Chief, whose source `real` makes.
    @MainActor
    public static func source(for id: ConversationID, own: any HomeChiefEngineSource, hold: LaunchChiefHold?,
                              real: @escaping @MainActor @Sendable (ConversationID) -> any HomeChiefEngineSource) -> any HomeChiefEngineSource {
        guard id == HomeLaunchChiefSource.conversation, let hold else { return own }
        return HomeLaunchChiefEngine(provisional: own) { await hold.resolved().map(real) }
    }
}
