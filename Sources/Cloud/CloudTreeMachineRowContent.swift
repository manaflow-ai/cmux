import CmuxCloud
import CmuxCloudMachines
import CmuxFoundation
import SwiftUI

/// Compact rows keep identity, resources and usage on one baseline; cards stack details.
/// This view receives only an immutable snapshot; the panel owns stats refreshes.
struct CloudTreeMachineRowContent: View {
    let machine: MachineSnapshot
    var style: CloudTreeStyle = CloudTreeStyleStore.current
    var now: Date = .now
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var fontMagnification

    var body: some View {
        CloudTreeMachineBand(style: style) {
            HStack(alignment: .top, spacing: scaled(style.iconGap)) {
                CloudTreeRowIcon(
                    style: style,
                    systemName: machine.freeAccess == .expired ? "lock.fill" : "cloud",
                    tint: CloudTreeIconPalette.machine
                )
                .frame(width: scaled(max(style.iconSlot, style.iconSize)), height: scaled(style.machineNameLineHeight))
                VStack(alignment: .leading, spacing: scaled(style.rowGrid.machineLineSpacing)) {
                    nameRow
                    if style.machineRowLayout == .twoLine {
                        Text(subtitle)
                            .cmuxFont(size: style.detailSize, design: style.fontDesign)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(height: scaled(style.machineSubtitleLineHeight))
                    }
                }
            }
            .padding(.vertical, scaled(style.machineVerticalPadding))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Machine identity retains its own line at every sidebar width.
    private var nameRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: style.rowGrid.dotGap) {
            HStack(alignment: .firstTextBaseline, spacing: style.rowGrid.dotGap) {
                Text(machine.displayName)
                    .cmuxFont(size: style.machineNameSize, weight: .medium, design: style.fontDesign)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
            }
            Spacer(minLength: 0)
        }
        .frame(height: scaled(style.machineNameLineHeight))
    }

    /// Combines this machine's identity, activity, and resource readings for assistive technology.
    var accessibilityLabel: String {
        var parts = [machine.displayName, machine.activityLabel, CloudMachineResourcePresentation(machine: machine, now: now).summary]
        parts.append(usageSummary)
        return parts.joined(separator: ", ")
    }

    /// Expands the row with its sample time, machine details, and optional billing usage.
    var toolTip: String {
        var lines = [machine.displayName, machine.activityLabel, CloudMachineResourcePresentation(machine: machine, now: now).summary]
        if let sampledAt = machine.stats?.resourceSampledAt {
            lines.append(String(
                format: String(localized: "cloudTree.resources.sampled", defaultValue: "Sampled %@"),
                sampledAt.formatted(date: .abbreviated, time: .standard)
            ))
        }
        lines.append(subtitle)
        lines.append(machine.image)
        lines.append(usageSummary)
        return lines.joined(separator: "\n")
    }

    /// A missing backend report remains visible instead of looking like a removed feature.
    var usageSummary: String {
        usageLine ?? String(localized: "machines.usage.unavailable", defaultValue: "Token usage unavailable")
    }

    /// "$1.23 · 41K tokens · 30d", including a measured zero. Nil means no report.
    var usageLine: String? {
        guard let usage = machine.usage, let cost = usageCost else { return nil }
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

    /// API-equivalent spend from a reported usage sample, including zero.
    private var usageCost: String? {
        guard let usage = machine.usage else { return nil }
        return Self.usdFormatter.string(from: NSNumber(value: usage.totals.apiEquivalentUsd))
            ?? String(format: "$%.2f", usage.totals.apiEquivalentUsd)
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
    var subtitle: String {
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

    /// Legacy summary retained for callers that use the machine row model;
    /// rendering now places these details in the Resources section.
    var inlineFact: String? {
        if machine.freeAccess == .expired {
            return String(localized: "machines.row.locked", defaultValue: "Locked")
        }
        var parts: [String] = []
        let metrics = CloudMachineResourcePresentation(machine: machine, now: now)
        if style.showsMachineStats {
            parts.append([metrics.cpu, metrics.memory, metrics.disk]
                .map { "\($0.label)\u{00A0}\($0.value)" }
                .joined(separator: " · "))
        }
        parts.append(usageSummary)
        return parts.joined(separator: " · ")
    }

    private func scaled(_ size: CGFloat) -> CGFloat {
        GlobalFontMagnification.scaledSize(size, percent: fontMagnification)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
