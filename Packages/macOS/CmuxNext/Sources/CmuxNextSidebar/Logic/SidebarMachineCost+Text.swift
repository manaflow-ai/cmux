public import Foundation

/// A Cloud machine's cost in words, for its sidebar header's tooltip and
/// Cloud Machine Status: "$0.26/h · Running 2h 14m · About $0.58 so far",
/// then the account's cap ("2 of 3 machines running"). Every number comes
/// from the server; this only formats it.
nonisolated extension SidebarMachine.Cost {
    /// The usage line, then the cap line, whichever exist.
    public func lines(now: Date, locale: Locale = .current) -> [String] {
        [usage(now: now, locale: locale), cap?.text].compactMap { $0 }
    }

    /// Rate, time running and the estimate so far; while paused only the
    /// rate, as "when running", so a paused machine shows no running cost.
    /// Nil without a rate or a running time.
    public func usage(now: Date, locale: Locale = .current) -> String? {
        guard let seconds = runningSeconds(now: now) else {
            return hourlyRateUsd.map { Strings.costRateWhenRunning(Self.price($0, locale: locale)) }
        }
        var parts: [String] = []
        if let rate = hourlyRateUsd { parts.append(Strings.costRate(Self.price(rate, locale: locale))) }
        parts.append(Strings.costRunning(Self.duration(seconds, locale: locale)))
        if let spent = estimatedCostUsd(now: now) {
            parts.append(spent < 0.01 ? Strings.costUnderSoFar(Self.price(0.01, locale: locale)) : Strings.costSoFar(Self.price(spent, locale: locale)))
        }
        return parts.joined(separator: " · ")
    }

    /// US dollars to the cent ("$0.26").
    static func price(_ usd: Double, locale: Locale) -> String {
        usd.formatted(.currency(code: "USD").precision(.fractionLength(2)).locale(locale))
    }

    /// Time running in at most two units ("2h 14m", "3d 4h"); under a minute reads as one.
    static func duration(_ seconds: TimeInterval, locale: Locale) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        return formatter.string(from: max(60, seconds)) ?? ""
    }
}

nonisolated extension SidebarMachine.Cost.Cap {
    /// "2 of 3 machines running", "1 running, no machine cap" or "Machines are closed on this plan".
    public var text: String {
        switch self {
        case let .uncapped(running): Strings.capNone(running)
        case let .capped(running, max): Strings.capOf(running, max)
        case .closed: Strings.capClosed
        }
    }
}
