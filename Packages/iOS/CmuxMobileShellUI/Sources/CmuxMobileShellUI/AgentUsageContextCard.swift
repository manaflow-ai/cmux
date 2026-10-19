import CmuxAgentChat
import Foundation
import SwiftUI

/// A compact context/allowance summary for an Agent Chat transcript.
///
/// The card is deliberately value-driven: the model can keep usage absent
/// when an older Mac has not implemented the optional history field, and the
/// caller can omit this view without introducing a loading state into the
/// conversation. Provider-reported values remain labeled as usage rather
/// than being presented as a billing promise.
public struct AgentUsageContextCard: View {
    private let presentation: AgentUsageContextPresentation

    public init(totals: ChatUsageTotals, now: Date = Date()) {
        self.presentation = AgentUsageContextPresentation(totals: totals, now: now)
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: presentation.systemImage)
                .foregroundStyle(presentation.isNearLimit ? Color.orange : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("Usage and context")
                    .font(.caption.weight(.semibold))
                Text(presentation.labels.joined(separator: " · "))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityIdentifier("MobileAgentUsageContextCard")
    }
}

/// Stable, testable display values for ``AgentUsageContextCard``.
struct AgentUsageContextPresentation: Equatable, Sendable {
    let labels: [String]
    let accessibilityLabel: String
    let systemImage: String
    let isNearLimit: Bool

    init(totals: ChatUsageTotals, now: Date = Date()) {
        var labels: [String] = []
        if let fraction = totals.contextUsedFraction {
            labels.append("\(Self.percent(fraction))% context")
        } else if let context = totals.contextTokens {
            labels.append("\(Self.compact(context)) context tokens")
        }
        if totals.usage.totalTokens > 0 {
            labels.append("\(Self.compact(totals.usage.totalTokens)) tokens")
        }
        var nearLimit = false
        if let rateLimit = totals.rateLimit {
            if rateLimit.spendControlReached == true {
                labels.append("Limit reached")
                nearLimit = true
            } else if let window = rateLimit.tightestWindow {
                labels.append("\(Self.percent(window.usedPercent / 100))% allowance")
                nearLimit = window.usedPercent >= 80
                if let resetsAt = window.resetsAt, resetsAt > now {
                    labels.append("Resets \(Self.relativeReset(resetsAt.timeIntervalSince(now)))")
                }
            }
        }
        if labels.isEmpty {
            labels.append("Usage unavailable")
        }
        self.labels = labels
        self.isNearLimit = nearLimit
        self.systemImage = nearLimit ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.67percent"
        self.accessibilityLabel = "Usage and context, " + labels.joined(separator: ", ")
    }

    private static func percent(_ fraction: Double) -> Int {
        Int((min(max(fraction, 0), 1) * 100).rounded())
    }

    private static func compact(_ value: Int) -> String {
        let absolute = abs(value)
        if absolute >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if absolute >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return String(value)
    }

    private static func relativeReset(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "in \(minutes)m" }
        let hours = max(1, Int((Double(minutes) / 60).rounded()))
        if hours < 24 { return "in \(hours)h" }
        return "in \(max(1, Int((Double(hours) / 24).rounded())))d"
    }
}
