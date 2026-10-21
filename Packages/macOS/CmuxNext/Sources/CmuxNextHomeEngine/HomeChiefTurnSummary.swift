import CmuxNextDaemon
import CmuxNextHome
import Foundation

/// The Diagnostics card's last turn in words a person reads (`HomeChiefLastTurnView`): the
/// engine by its names ("Claude · Opus 5.5 · High", never `claude-sr2-pipe`), when it ended, and
/// four measures: its time, its cost (its tokens when the harness reports no price), the share
/// of the prompt read from the cache, and its tool calls. Numbers follow `locale`.
nonisolated struct HomeChiefTurnSummary: Equatable {
    /// One measure: its value over its name, and a note under it ("1 failed").
    nonisolated struct Metric: Equatable {
        var label: String
        var value: String
        var note: String?
    }

    var engine: String
    /// "2 min. ago"; nil when the trace did not say when.
    var ended: String?
    var metrics: [Metric]
    /// The error a failed turn ended with.
    var error: String?

    /// - Parameters:
    ///   - models: The models the brain offers, which name a model by its catalog name.
    ///   - now: The time `ended` counts back from.
    init(_ turn: HomeEngineTurn, models: [ChiefEngineReport.Model] = [], now: Date = Date(), locale: Locale = .current) {
        engine = Self.engine(turn, models: models)
        ended = turn.ended.map { date in
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = locale
            formatter.unitsStyle = .short
            return formatter.localizedString(for: min(date, now), relativeTo: now)
        }
        let spend = Self.cost(turn.cost, locale: locale).map { Metric(label: HomeChiefCardStrings.cost, value: $0) }
            ?? Self.tokens(turn.tokens, locale: locale).map { Metric(label: HomeChiefCardStrings.tokens, value: $0) }
            ?? Metric(label: HomeChiefCardStrings.cost, value: Self.missing)
        let failed = turn.toolErrors > 0
            ? String(localized: "home.engine.toolFailures", defaultValue: "\(turn.toolErrors) failed", table: "Home", bundle: .module) : nil
        metrics = [
            Metric(label: HomeChiefCardStrings.time, value: Self.seconds(turn.seconds, locale: locale)),
            spend,
            Metric(label: HomeChiefCardStrings.cache, value: Self.cache(turn.hitRate, locale: locale)),
            Metric(label: HomeChiefCardStrings.tools, value: turn.tools.formatted(.number.locale(locale)), note: failed),
        ]
        let error = turn.error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.error = error.isEmpty ? nil : error
    }

    /// What a measure the turn did not report shows.
    static let missing = "\u{2013}"

    /// "Claude (SR2 Pipe) · Opus 5.5 · High": the harness, model and effort by name.
    static func engine(_ turn: HomeEngineTurn, models: [ChiefEngineReport.Model]) -> String {
        let harness = turn.harness == "?" ? nil : ChiefBackend.title(for: turn.harness)
        let model = turn.model.map { HomeChiefModelMenu.name(of: $0, in: models) }
        let effort = turn.effort.map(HomeEngineStrings.effortTitle)
        return [harness, model, effort].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    /// "7.8s": the unit in the reader's language, from Foundation.
    static func seconds(_ seconds: Double, locale: Locale) -> String {
        Measurement(value: seconds, unit: UnitDuration.seconds)
            .formatted(.measurement(width: .narrow, numberFormatStyle: .number.precision(.fractionLength(1))).locale(locale))
    }

    /// "50%", or a dash when the turn reported no cache use.
    static func cache(_ rate: Double?, locale: Locale) -> String {
        guard let rate else { return missing }
        return rate.formatted(.percent.locale(locale).precision(.fractionLength(0)).rounded(rule: .toNearestOrAwayFromZero))
    }

    /// "$0.144" (cents for a dollar or more); "<$0.001" for less than a tenth of a cent; nil when
    /// the harness reported no price.
    static func cost(_ usd: Double?, locale: Locale) -> String? {
        guard let usd, usd >= 0 else { return nil }
        let style = FloatingPointFormatStyle<Double>.Currency(code: "USD", locale: locale)
        if usd > 0, usd < 0.001 { return "<" + 0.001.formatted(style.precision(.fractionLength(3))) }
        return usd.formatted(style.precision(.fractionLength(usd >= 1 ? 2 : 3)))
    }

    /// "12.3K"; nil when the turn reported no usage.
    static func tokens(_ count: Double?, locale: Locale) -> String? {
        guard let count, count > 0 else { return nil }
        return count.formatted(.number.locale(locale).notation(.compactName).precision(.significantDigits(1...3)))
    }
}
