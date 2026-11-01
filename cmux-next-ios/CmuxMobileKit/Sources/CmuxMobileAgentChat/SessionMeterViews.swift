#if os(iOS)
import CmuxMobileDesign
import SwiftUI

/// The context meter in the composer's controls row, after the ACP web UI's context ring
/// (`ComposerPickers.tsx` `ContextRing`): a gauge that fills clockwise from 12 o'clock
/// over a visible track (a solid pie, so it never reads as an activity spinner), with the
/// share used beside it. It turns to the warning tint at 80 %. Tapping opens the details:
/// the share used, a bar and the tokens used of the window.
struct ContextUsageRing: View {
    let usage: ContextUsage
    @State private var showsDetails = false

    var body: some View {
        Button { showsDetails = true } label: {
            HStack(spacing: 4) {
                ContextUsagePie(fraction: usage.fraction, tint: tint)
                    .frame(width: 16, height: 16)
                Text("\(usage.percent)%")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(usage.isNearlyFull ? Color.cmuxMobileWarning : .secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .contentTransition(.numericText(value: Double(usage.percent)))
            }
            .padding(.horizontal, 6)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Context used")
        .accessibilityValue(Text("\(usage.percent) percent, \(usage.tokensLabel)"))
        .popover(isPresented: $showsDetails) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Context window").font(.caption).foregroundStyle(.secondary)
                Text("\(usage.percent)% used").font(.subheadline.weight(.medium)).padding(.top, 2)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.14))
                        Capsule().fill(tint).frame(width: proxy.size.width * usage.fraction)
                    }
                }
                .frame(height: 4)
                .padding(.top, 8)
                Text(usage.tokensLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            .padding(14)
            .frame(width: 240, alignment: .leading)
            .presentationCompactAdaptation(.popover)
        }
    }

    /// The user's accent (Settings > Appearance > Accent color), never a fixed hue.
    private var tint: Color { usage.isNearlyFull ? .cmuxMobileWarning : .cmuxMobileAccent }
}

/// A filled pie on a track ring: the used share is a wedge from 12 o'clock.
private struct ContextUsagePie: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        ZStack {
            Circle().fill(Color.primary.opacity(0.12))
            Circle().strokeBorder(tint.opacity(0.55), lineWidth: 1.5)
            PieWedge(fraction: fraction)
                .fill(tint)
                .padding(3)
                .animation(.cmuxMobileSmooth, value: fraction)
        }
    }
}

private struct PieWedge: Shape {
    var fraction: Double
    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard fraction > 0 else { return path }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: center)
        path.addArc(center: center, radius: min(rect.width, rect.height) / 2,
                    startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * min(fraction, 1)), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// The running turn's plan pinned above the composer: progress, count and the current step.
/// Tapping expands the whole checklist.
struct PlanProgressBar: View {
    let progress: PlanProgress
    let entries: [ACPPlanEntry]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.cmuxMobileSmooth) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().stroke(Color.cmuxMobileFillSelected, lineWidth: 2.5)
                        Circle()
                            .trim(from: 0, to: Double(progress.completed) / Double(max(progress.total, 1)))
                            .stroke(Color.cmuxMobileSuccess, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.cmuxMobileSmooth, value: progress.completed)
                    }
                    .frame(width: 16, height: 16)
                    Text(progress.current ?? "Plan complete")
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(progress.countLabel)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: entry.status == .completed ? "checkmark.circle.fill"
                                  : (entry.status == .inProgress ? "circle.dotted" : "circle"))
                                .foregroundStyle(entry.status == .completed ? Color.cmuxMobileSuccess : .secondary)
                            Text(entry.content).font(.footnote)
                                .foregroundStyle(entry.status == .completed ? .secondary : .primary)
                        }
                    }
                }
                .padding(.bottom, 10)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Plan, \(progress.completed) of \(progress.total) done. \(progress.current ?? "")"))
    }
}
#endif
