import Foundation

/// Formatting for the machine card's live resource and coderouter readouts.
/// Kept separate from the row layout so the default card can stay small and
/// the readout rules remain easy to exercise in isolation.
extension CloudTreeMachineRowContent {
    /// "CPU 9% · RAM 3.4/3.8 GB · Disk 2.8/3.1 GB" for an awake machine, the
    /// asleep line otherwise; nil when there is nothing to say yet.
    static func statsLine(_ stats: VMStats) -> String? {
        switch stats.state {
        case .awake:
            var parts: [String] = []
            if let cpu = stats.cpuPercent {
                parts.append(String(format: String(localized: "cloudTree.stats.cpu", defaultValue: "CPU %d%%"), Int(cpu.rounded())))
            }
            if let used = stats.memoryUsedMb, let total = stats.memoryTotalMb, total > 0 {
                parts.append(String(format: String(localized: "cloudTree.stats.memory", defaultValue: "RAM %@/%@ GB"), gb(used), gb(total)))
            }
            if let used = stats.diskUsedMb, let total = stats.diskTotalMb, total > 0 {
                parts.append(String(format: String(localized: "cloudTree.stats.disk", defaultValue: "Disk %@/%@ GB"), gb(used), gb(total)))
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .asleep:
            return String(localized: "machines.stats.asleep", defaultValue: "Asleep \u{00B7} free while it sleeps")
        case .unknown:
            return nil
        }
    }

    /// A stable resource line for the machine card. The labels stay present
    /// while a first sample is in flight, so the row never collapses into an
    /// unexplained blank area or a clipped trailing string.
    static func resourceLine(_ stats: VMStats?) -> String {
        guard let stats else {
            return String(localized: "cloudTree.stats.pending", defaultValue: "CPU — · RAM — · Disk —")
        }

        let cpu: String
        switch stats.state {
        case .awake:
            cpu = stats.cpuPercent.map { "\(Int($0.rounded()))%" } ?? "—"
        case .asleep, .unknown:
            cpu = "—"
        }

        let memory: String
        if let used = stats.memoryUsedMb, let total = stats.memoryTotalMb, total > 0 {
            memory = "\(gb(used))/\(gb(total)) GB"
        } else if let total = stats.memoryTotalMb, total > 0 {
            memory = "\(gb(total)) GB"
        } else {
            memory = "—"
        }

        let disk: String
        if let used = stats.diskUsedMb, let total = stats.diskTotalMb, total > 0 {
            disk = "\(gb(used))/\(gb(total)) GB"
        } else if let total = stats.diskTotalMb, total > 0 {
            disk = "\(gb(total)) GB"
        } else {
            disk = "—"
        }

        var line = String(
            format: String(localized: "cloudTree.stats.line", defaultValue: "CPU %@ · RAM %@ · Disk %@"),
            cpu, memory, disk
        )
        if stats.state == .asleep {
            line += String(localized: "cloudTree.stats.asleepSuffix", defaultValue: " · Asleep")
        }
        return line
    }

    private static func gb(_ mb: Int) -> String {
        let value = Double(mb) / 1024
        return value >= 10 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    /// "$1.23 · 41K tokens · 30d": coderouter spend over the usage window. Nil
    /// when the machine routed nothing, so an idle machine shows no spend row.
    static func usageLine(_ usage: MachineUsageSnapshot) -> String? {
        guard !usage.totals.isEmpty else { return nil }
        let cost = usdFormatter.string(from: NSNumber(value: usage.totals.apiEquivalentUsd))
            ?? String(format: "$%.2f", usage.totals.apiEquivalentUsd)
        let tokens = usage.totals.totalTokens.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
        let period = String(
            format: String(localized: "machines.usage.period.days", defaultValue: "%dd"),
            usage.periodDays
        )
        return String(
            format: String(localized: "machines.usage.line", defaultValue: "%1$@ \u{00B7} %2$@ tokens \u{00B7} %3$@"),
            cost, tokens, period
        )
    }

    /// API-equivalent spend is always in US dollars, whatever the user's locale.
    private static let usdFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.currencySymbol = "$"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    /// The two-line layout's second line. Deliberately excludes the free-access
    /// countdown: expiry is plan chrome (the panel header owns it), not a fact
    /// about the machine. "Locked" stays — it explains a dead machine row.
    static func subtitle(_ machine: MachineSnapshot) -> String {
        var parts: [String] = []
        if machine.showsName {
            // Named machines keep their address visible: the id is what CLI
            // verbs and URLs use.
            parts.append(machine.id)
        }
        parts.append(machine.kindLabel)
        if let createdAt = machine.createdAt {
            parts.append(Self.relativeFormatter.localizedString(for: createdAt, relativeTo: Date()))
        }
        if machine.freeAccess == .expired {
            parts.append(String(localized: "machines.row.locked", defaultValue: "Locked"))
        }
        return parts.joined(separator: " · ")
    }

    /// The single-line layout's one dim fact: "Locked" when expired, else nothing.
    static func inlineFact(_ machine: MachineSnapshot, style: CloudTreeStyle) -> String? {
        if machine.freeAccess == .expired {
            return String(localized: "machines.row.locked", defaultValue: "Locked")
        }
        // Single-line rows carry the live reading inline: the same CPU/RAM/Disk
        // line the two-line card shows, dimmed after the name, then the
        // coderouter spend when the backend reports any.
        var parts: [String] = []
        if style.showsMachineStats, let stats = machine.stats, let line = statsLine(stats) {
            parts.append(line)
        }
        if let usage = machine.usage, let line = usageLine(usage) {
            parts.append(line)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
}
