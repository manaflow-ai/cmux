public import CMUXAgentLaunch
public import SwiftUI

/// The interactive action area for an exit-plan feed item. It renders the
/// agent's plan, any allowed prompts and plan-file reference, and (while the
/// item is pending) a feedback field plus the Ultraplan/Manual/Auto approval
/// buttons; once resolved it shows the submitted badge.
///
/// Feedback always wins over mode: a non-empty feedback string is sent as a
/// block+reason regardless of which button is pressed, mirroring the hook's
/// translation. The view takes only value snapshots plus closures so it can
/// live below the Feed's list snapshot boundary.
///
/// The `feed.exitplan.*`/`feed.badge.*` localization keys resolve against the
/// app's main bundle (`bundle: .main`) so the app-side `.xcstrings` catalog and
/// its non-English translations keep working from the package.
public struct ExitPlanActionArea: View {
    let plan: String
    let source: WorkstreamSource
    let status: WorkstreamStatus
    let isRowSelected: Bool
    let onFocusRow: () -> Void
    let onActionRow: () -> Void
    let onBlurRow: () -> Void
    let onApprove: (WorkstreamExitPlanMode, String?) -> Void

    public init(
        plan: String,
        source: WorkstreamSource,
        status: WorkstreamStatus,
        isRowSelected: Bool,
        onFocusRow: @escaping () -> Void,
        onActionRow: @escaping () -> Void,
        onBlurRow: @escaping () -> Void,
        onApprove: @escaping (WorkstreamExitPlanMode, String?) -> Void
    ) {
        self.plan = plan
        self.source = source
        self.status = status
        self.isRowSelected = isRowSelected
        self.onFocusRow = onFocusRow
        self.onActionRow = onActionRow
        self.onBlurRow = onBlurRow
        self.onApprove = onApprove
    }

    @State private var feedback: String = ""
    @FocusState private var feedbackFocused: Bool

    private var trimmedFeedback: String {
        feedback.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var hasFeedback: Bool { !trimmedFeedback.isEmpty }
    private var preview: WorkstreamExitPlanPreview {
        WorkstreamExitPlanPreview(rawPlan: plan)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PlanBodyView(
                plan: preview.planText,
                rendersMarkdown: source == .claude
            )
            if !preview.allowedPrompts.isEmpty {
                ExitPlanAllowedPromptsView(prompts: preview.allowedPrompts)
            }
            if let path = preview.planFilePath {
                ExitPlanPlanFileView(path: path)
            }
            if status.isPending {
                TextField(
                    String(
                        localized: "feed.exitplan.feedback.placeholder",
                        defaultValue: "Tell Claude what to change…",
                        bundle: .main
                    ),
                    text: $feedback,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .tint(Color.primary.opacity(0.75))
                .focused($feedbackFocused)
                .lineLimit(2...5)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(feedbackFocused ? 0.075 : 0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(
                            Color.primary.opacity(feedbackFocused ? 0.20 : (hasFeedback ? 0.25 : 0.10)),
                            lineWidth: 1
                        )
                )
                .onChange(of: feedbackFocused) { _, focused in
                    if focused {
                        onFocusRow()
                    } else {
                        onBlurRow()
                    }
                }
                HStack(spacing: 6) {
                    FeedButton(
                        label: hasFeedback
                            ? String(localized: "feed.exitplan.refine",
                                     defaultValue: "Send feedback", bundle: .main)
                            : String(localized: "feed.exitplan.ultraplan",
                                     defaultValue: "Ultraplan", bundle: .main),
                        kind: hasFeedback ? .primary : .soft,
                        size: .medium, fullWidth: true
                    ) {
                        feedbackFocused = false
                        onActionRow()
                        // Feedback always wins over mode; hook translates
                        // non-empty feedback into block+reason.
                        onApprove(hasFeedback ? .manual : .ultraplan, hasFeedback ? trimmedFeedback : nil)
                    }
                    FeedButton(
                        label: String(localized: "feed.exitplan.manual",
                                      defaultValue: "Manual", bundle: .main),
                        kind: .soft,
                        size: .medium, fullWidth: true,
                        dimmed: hasFeedback
                    ) {
                        feedbackFocused = false
                        onActionRow()
                        onApprove(.manual, hasFeedback ? trimmedFeedback : nil)
                    }
                    FeedButton(
                        label: String(localized: "feed.exitplan.auto",
                                      defaultValue: "Auto", bundle: .main),
                        kind: .success,
                        size: .medium, fullWidth: true,
                        dimmed: hasFeedback
                    ) {
                        feedbackFocused = false
                        onActionRow()
                        onApprove(.autoAccept, hasFeedback ? trimmedFeedback : nil)
                    }
                }
            } else if let badge = submittedBadge {
                FeedButton(
                    label: badge,
                    leadingIcon: "checkmark",
                    kind: .success,
                    size: .medium,
                    fullWidth: true,
                    dimmed: true
                ) {}
            }
        }
        .onChange(of: isRowSelected) { _, selected in
            if !selected {
                feedbackFocused = false
            }
        }
    }

    private var submittedBadge: String? {
        guard case .resolved(let decision, _) = status else { return nil }
        let submitted = String(localized: "feed.badge.submitted", defaultValue: "Submitted", bundle: .main)
        switch decision {
        case .exitPlan(let mode, let feedback):
            if let feedback, !feedback.isEmpty {
                return "\(submitted) · " + String(
                    localized: "feed.badge.refined", defaultValue: "refined", bundle: .main
                )
            }
            return "\(submitted) · \(mode.displayLabel)"
        default:
            return submitted
        }
    }
}
