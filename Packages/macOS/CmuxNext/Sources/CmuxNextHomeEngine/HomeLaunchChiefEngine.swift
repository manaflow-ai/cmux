public import CmuxHomeCore
public import CmuxNextHome
import CmuxNextHomeModel

/// The settings card of a bare launch's Chief page (`HomeLaunchComposer`) before the Chief's
/// owner answers. It reads what the page shows (the Chief the launch will most likely open);
/// a change the person makes there (model, effort, harness) waits for the real Chief and is then
/// made on it, never dropped on the provisional one. A page that went or quit first refuses it.
public nonisolated struct HomeLaunchChiefEngine: HomeChiefEngineSource {
    /// The card's source for the provisional Chief (what it reads while nothing else answers).
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

    /// What the provisional Chief's source reads; when it cannot answer yet (a hosted Chief not
    /// listed), the real Chief's once it is named.
    public func read() async throws(HomeChiefEngineError) -> HomeChiefSnapshot {
        do throws(HomeChiefEngineError) {
            return try await provisional.read()
        } catch {
            guard let real = await chief() else { throw error }
            return try await real.read()
        }
    }

    /// Made on the real Chief once it is named (waits until then).
    public func set(_ fields: [String: String?]) async throws(HomeChiefEngineError) -> HomeChiefSnapshot {
        guard let real = await chief() else { throw provisional.isLocal ? .localUnreachable : .cloudUnreachable }
        return try await real.set(fields)
    }

    /// The Chief a bare launch will most likely open, from what this Mac knows before any read:
    /// a cloud Chief while someone is signed in and the Engine row (`home.chiefEngine`) does not
    /// pick this Mac's (Auto picks it only while this Mac's Chief runs). That is what the Chief tab's
    /// rule (`HomeCloudChiefs.chiefTab`) answers once the cloud read lists the Hosted Chief, and a
    /// fresh home's own Chief has no history to keep the tab. Signed out: this Mac's Chief.
    public static func guessesCloud(signedIn: Bool, engine: String?, localRunning: Bool) -> Bool {
        signedIn && !HomeChiefDefault(setting: engine).prefersLocal(localRunning: localRunning)
    }

    /// The card's source for conversation `id`: `own` itself, unless `id` is a bare launch's
    /// provisional Chief (`HomeLaunchChiefSource.conversation`) with a page holding its sends;
    /// then a change waits for the real Chief, whose source `real` makes.
    @MainActor
    public static func source(for id: ConversationID, own: any HomeChiefEngineSource, hold: LaunchChiefHold?,
                              real: @escaping @MainActor @Sendable (ConversationID) -> any HomeChiefEngineSource) -> any HomeChiefEngineSource {
        guard id == HomeLaunchChiefSource.conversation, let hold else { return own }
        return HomeLaunchChiefEngine(provisional: own) { await hold.resolved().map(real) }
    }
}
