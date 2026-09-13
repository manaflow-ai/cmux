import CmuxCloudMachines
import CmuxFoundation
import SwiftUI

/// Resource readings stay below the name, aligned across machines at every width.
/// This view receives only an immutable snapshot; the panel owns stats refreshes.
struct CloudTreeMachineRowContent: View {
    let machine: MachineSnapshot
    var style: CloudTreeStyle = CloudTreeStyleStore.current

    var body: some View {
        CloudTreeMachineBand(style: style) {
            HStack(alignment: .top, spacing: CloudTreeRowGrid.dotGap) {
                Image(systemName: machine.freeAccess == .expired ? "lock.fill" : "cloud")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: CloudTreeRowGrid.dotSlot, height: style.machineNameLineHeight)
                VStack(alignment: .leading, spacing: CloudTreeRowGrid.machineLineSpacing) {
                    HStack(alignment: .firstTextBaseline, spacing: CloudTreeRowGrid.dotGap) {
                        Text(machine.displayName)
                            .cmuxFont(size: style.machineNameSize, weight: .medium, design: style.fontDesign)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if machine.isDefault {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .help(String(localized: "machines.row.default.help", defaultValue: "Default machine for New Cloud Workspace"))
                        }
                        if let fact = inlineFact {
                            Text(fact)
                                .cmuxFont(size: style.detailSize, design: style.fontDesign)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: style.machineNameLineHeight)
                    if style.showsMachineStats {
                        CloudTreeMachineResourceView(metrics: CloudMachineResourcePresentation(machine: machine), style: style)
                            .padding(.top, 3)
                    }
                    if style.machineRowLayout == .twoLine {
                        Text(subtitle)
                            .cmuxFont(size: style.detailSize, design: style.fontDesign)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(height: style.machineSubtitleLineHeight)
                    }
                }
            }
            .padding(.vertical, style.machineVerticalPadding)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Combines this machine's identity, activity, and resource readings for assistive technology.
    var accessibilityLabel: String {
        var parts = [machine.displayName, machine.activityLabel, CloudMachineResourcePresentation(machine: machine).summary]
        if machine.isDefault {
            parts.append(String(localized: "machines.row.default.accessibilityLabel", defaultValue: "Default machine"))
        }
        return parts.joined(separator: ", ")
    }

    /// Expands the row with its sample time, machine details, and optional billing usage.
    var toolTip: String {
        var lines = [machine.displayName, machine.activityLabel, CloudMachineResourcePresentation(machine: machine).summary]
        if let stats = machine.stats {
            lines.append(String(
                format: String(localized: "cloudTree.resources.sampled", defaultValue: "Sampled %@"),
                stats.sampledAt.formatted(date: .abbreviated, time: .standard)
            ))
        }
        lines.append(subtitle)
        lines.append(machine.image)
        if let usageLine { lines.append(usageLine) }
        return lines.joined(separator: "\n")
    }

    /// "$1.23 · 41K tokens · 30d": coderouter spend over the usage window. Nil
    /// when the machine routed nothing, so an idle machine shows no spend row.
    var usageLine: String? {
        guard let usage = machine.usage, !usage.totals.isEmpty else { return nil }
        let cost = Self.usdFormatter.string(from: NSNumber(value: usage.totals.apiEquivalentUsd))
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

    /// Locked explains access behavior; resource and billing details have their own homes.
    var inlineFact: String? {
        machine.freeAccess == .expired
            ? String(localized: "machines.row.locked", defaultValue: "Locked")
            : nil
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
