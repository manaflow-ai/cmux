import CmuxTerminalCore
import Foundation

/// Which physical keys produce agent key hints' chords, for the hint tooltip.
///
/// Hover asks synchronously and never waits. The sources
/// (``AgentKeyHintPhysicalKeyboardReader``) are read on a background task
/// at first use, when `karabiner.json` changes (checked at most every
/// ``karabinerCheckInterval``), and at most every ``rereadInterval`` for
/// `hidutil`, System Settings, and connected keyboards. Until the first
/// read finishes, hints show only their printed keys. Display only: what a
/// click sends is unaffected.
@MainActor
final class AgentKeyHintPhysicalKeyboardStore {
    static let shared = AgentKeyHintPhysicalKeyboardStore(reader: .live)

    /// How long hover trusts an earlier check of `karabiner.json`.
    static let karabinerCheckInterval: TimeInterval = 5
    /// How long a read of the other sources stays good.
    static let rereadInterval: TimeInterval = 60

    private let reader: AgentKeyHintPhysicalKeyboardReader
    private let now: () -> TimeInterval
    private var setup: PhysicalKeyboardSetup?
    private var adviceByKeys: [[String]: [PhysicalKeyAdvice]] = [:]
    private var readAt: TimeInterval?
    private var karabinerCheckedAt: TimeInterval?
    private var karabinerStamp: AgentKeyHintPhysicalKeyboardReader.FileStamp?
    private var isReading = false

    /// - Parameters:
    ///   - reader: Where the sources are read from.
    ///   - now: A monotonic clock in seconds.
    init(
        reader: AgentKeyHintPhysicalKeyboardReader,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.reader = reader
        self.now = now
    }

    /// Physical keys to press for a hint's `keys` where they differ from
    /// the printed ones; empty until the sources are read.
    func advice(forAgentKeys keys: [String]) -> [PhysicalKeyAdvice] {
        refreshIfNeeded()
        guard let setup else { return [] }
        if let cached = adviceByKeys[keys] { return cached }
        let advice = setup.advice(forAgentKeys: keys)
        adviceByKeys[keys] = advice
        return advice
    }

    private func refreshIfNeeded() {
        guard !isReading else { return }
        let time = now()
        var due = readAt.map { time - $0 >= Self.rereadInterval } ?? true
        if !due, karabinerCheckedAt.map({ time - $0 >= Self.karabinerCheckInterval }) ?? true {
            karabinerCheckedAt = time
            due = reader.karabinerStamp() != karabinerStamp
        }
        guard due else { return }
        isReading = true
        let reader = reader
        Task.detached(priority: .utility) { [weak self] in
            let result = reader.read()
            await self?.finishRead(setup: result.setup, karabinerStamp: result.karabinerStamp)
        }
    }

    private func finishRead(setup: PhysicalKeyboardSetup, karabinerStamp: AgentKeyHintPhysicalKeyboardReader.FileStamp) {
        self.setup = setup
        self.karabinerStamp = karabinerStamp
        adviceByKeys = [:]
        let time = now()
        readAt = time
        karabinerCheckedAt = time
        isReading = false
    }
}
