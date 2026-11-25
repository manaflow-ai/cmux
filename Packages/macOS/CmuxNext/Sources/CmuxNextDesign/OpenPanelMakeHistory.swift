import Foundation

/// What this app last saw of its panel service: how long its last `NSOpenPanel()` held the main thread, kept across
/// launches of the app (its user defaults). ``MadeAheadPanelStore`` makes a panel ahead of a click (a speculative
/// make) only when this proves the service answered fast; nothing off the main thread can ask the service first
/// (AppKit makes the panel only on the main thread and has no way to reach its view service without making one).
///
/// Why: the warm-up's `NSOpenPanel()` waits on the panel service inside `-[NSSavePanel _initBridgeAndStuff]`, and on a
/// loaded Mac (several cmux apps at once, builds) that held the main thread 2 to 60 s, once per launch (73 reports of
/// hang signature 2dc58e2ab1, each from its own process). With this record a slow, dead or unfinished make stops every
/// later warm-up of the app, in this process and the next launches, until a click (which makes its panel anyway) shows
/// the service fast again. So a speculative make never runs on no evidence, and runs at most once per process.
@MainActor
final class OpenPanelMakeHistory {
    /// A make at or under this is fast: a process's first panel takes about 300 to 400 ms on a working host, a later
    /// one 100 to 140 ms; 1.5 s was a loaded host (picker.md).
    nonisolated static let fastBound: Duration = .seconds(1)

    /// This process, so a record names the process that wrote it (a pid repeats across launches; this does not).
    nonisolated static let thisProcess = UUID().uuidString

    /// The last make, as stored.
    nonisolated struct Record: Codable, Equatable, Sendable {
        nonisolated enum Outcome: String, Codable, Sendable {
            /// Made, alive, within ``OpenPanelMakeHistory/fastBound``.
            case fast
            /// Made and alive, but slower than the bound.
            case slow
            /// Made, but its view service never answered (no prompt).
            case dead
            /// Started and not finished: written before the make, so a process that ended inside it (quit or killed
            /// during the freeze) leaves this behind, which reads as slow.
            case started
        }
        var outcome: Outcome
        /// The main thread's wait in `NSOpenPanel()`, seconds; nil while ``Outcome/started``.
        var seconds: Double?
        /// Whether a warm-up made it (not a click).
        var speculative: Bool
        /// ``OpenPanelMakeHistory/thisProcess`` of the process that made it.
        var process: String
    }

    private let defaults: UserDefaults
    private let process: String
    private static let recordKey = "openPanel.lastMake"
    private static let warmedKey = "openPanel.warmedProcess"

    /// - Parameters:
    ///   - defaults: Where the record lives: the app's own defaults, so every launch of this app (bundle) reads it.
    ///   - process: This process's mark; tests pass their own to stand for another launch.
    init(defaults: UserDefaults = .standard, process: String = OpenPanelMakeHistory.thisProcess) {
        self.defaults = defaults
        self.process = process
    }

    /// The last make of this app, from any of its launches.
    var last: Record? {
        guard let data = defaults.data(forKey: Self.recordKey) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    /// Whether a warm-up may make a panel now, and if not, why (for the store's one log notice).
    func warmUpRefusal() -> String? {
        if defaults.string(forKey: Self.warmedKey) == process { return "this process already made its one warm-up panel" }
        guard let last else { return "no panel of this app was made fast yet (the first click makes one)" }
        switch last.outcome {
        case .fast: return nil
        case .slow: return "the last panel took \(Self.format(last.seconds)) on the main thread"
        case .dead: return "the last panel came back dead (its view service never answered)"
        case .started: return last.process == process
            ? "a panel is being made" : "a launch ended inside its NSOpenPanel() (quit or killed during the wait)"
        }
    }

    /// Marks a make about to start, before the main thread waits on the service.
    func willMake(speculative: Bool) {
        if speculative { defaults.set(process, forKey: Self.warmedKey) }
        store(Record(outcome: .started, seconds: nil, speculative: speculative, process: process))
    }

    /// Records how the make that ``willMake(speculative:)`` marked ended.
    func didMake(took: Duration, alive: Bool, speculative: Bool) {
        let outcome: Record.Outcome = !alive ? .dead : took <= Self.fastBound ? .fast : .slow
        store(Record(outcome: outcome, seconds: Self.seconds(took), speculative: speculative, process: process))
    }

    private func store(_ record: Record) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Self.recordKey)
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private static func format(_ seconds: Double?) -> String {
        guard let seconds else { return "an unknown time" }
        return String(format: "%.2f s", seconds)
    }
}
