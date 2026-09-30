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
    var resources: CloudTreeMachineResourceSection? = nil
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var fontMagnification

    var body: some View {
        CloudTreeMachineBand(style: style) {
            HStack(alignment: .top, spacing: scaled(style.iconGap)) {
                if machine.freeAccess == .expired {
                    CloudTreeRowIcon(style: style, systemName: "lock.fill", tint: CloudTreeIconPalette.machine)
                } else {
                    Color.clear
                }
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
                    // Generated names use adjective-colour-noun, so the tail is the
                    // word that distinguishes machines. Keep both ends when space is tight.
                    .truncationMode(.middle)
                    .layoutPriority(1)
            }
            Spacer(minLength: 0)
        }
        .frame(height: scaled(style.machineNameLineHeight))
    }

    /// Combines this machine's identity, activity, and resource readings for assistive technology.
    ///
    /// `subtitle` in the same position the tooltip puts it: the default preset
    /// is single-line, so the id and the created-at are not rendered anywhere
    /// and the pointer only reaches them by hovering. Assistive technology has
    /// no pointer, so without this the row says less to the people who have the
    /// least other way to get it. `subtitle` always has at least the kind, so
    /// there is no empty component to filter.
    var accessibilityLabel: String {
        var parts = [machine.displayName, machine.activityLabel, metrics.summary]
        parts.append(subtitle)
        parts.append(usageSummary)
        return parts.joined(separator: ", ")
    }

    /// Expands the row with its sample time, machine details, and optional billing usage.
    var toolTip: String {
        var lines = [machine.displayName, machine.activityLabel, metrics.summary]
        if let sampledAt = machine.stats?.resourceSampledAt {
            lines.append(String(
                format: String(localized: "cloudTree.resources.sampled", defaultValue: "Sampled %@"),
                sampledAt.formatted(date: .abbreviated, time: .standard)
            ))
        }
        lines.append(subtitle)
        lines.append(machine.image)
        lines.append(usageSummary)
        // A machine the catalog found before the fleet list named it is built
        // with `image: info.image ?? ""`, and an empty line in the middle of a
        // popup reads as a missing fact rather than an absent one.
        return lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// A missing backend report remains visible instead of looking like a removed feature.
    var usageSummary: String {
        resources?.usageSummary ?? usageLine ?? String(localized: "machines.usage.unavailable", defaultValue: "Token usage unavailable")
    }

    private var metrics: CloudMachineResourcePresentation {
        resources?.metrics ?? CloudMachineResourcePresentation(machine: machine, now: now)
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
            // `now`, not `Date()`: every other part of this struct reads the
            // injected clock, so the age was the one value a test could not
            // pin. Both shipping call sites leave `now` at its default, so
            // this changes no rendered text today.
            parts.append(Self.relativeFormatter.localizedString(for: createdAt, relativeTo: now))
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
        if style.showsMachineStats {
            let metrics = self.metrics
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
