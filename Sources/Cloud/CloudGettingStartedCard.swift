import AppKit
import CmuxCloud
import CmuxFoundation
import SwiftUI

/// What the card's buttons do. The panel binds them to the same paths its
/// other entrypoints use (the New Cloud Machine action, the Cloud agent
/// launcher, the Cloud Secrets sheet), so the card adds no new behavior.
struct CloudGettingStartedActions {
    /// Opens Cloud Secrets. nil: the step shows the CLI import to copy.
    var openSecrets: (() -> Void)?
    var createMachine: () -> Void
    /// Opens a local agent that knows the `cmux vm` CLI. nil hides the button.
    var openLocalAgent: (() -> Void)?
    var dismiss: () -> Void
    /// Opens the first-run tour that does all three steps at once. nil hides it.
    var startFirstAgent: (() -> Void)? = nil
}

/// The Cloud panel's "Get started" card, pinned under the machine list.
///
/// One quiet card in Cursor's getting-started shape: the title is the
/// strongest text, with a progress count and ring beside it; one row per
/// step; and only the current step opens into one line of why, one compact
/// action and a subtle "Learn more". Finished steps keep their row with a
/// check so the user sees what already happened; later steps stay one dim
/// line. Once every step is done the card reads "You're set up" with a quiet
/// check until the panel retires it on a later open. The close button shows
/// on hover, and the card never comes back once closed.
struct CloudGettingStartedCard: View {
    let checklist: CloudGettingStartedChecklist
    let actions: CloudGettingStartedActions

    @State private var isHovered = false
    @State private var copiedCommand: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, checklist.isComplete ? 2 : 6)
            if checklist.isComplete {
                completedBody
                    .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(checklist.steps, id: \.self) { step in
                        stepRow(step)
                    }
                }
                if let startFirstAgent = actions.startFirstAgent, !checklist.isDone(.startAgent) {
                    allAtOnceButton(startFirstAgent)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .padding(.horizontal, RightSidebarChromeMetrics.barHorizontalPadding)
        .padding(.vertical, 8)
        .onHover { hovering in
            isHovered = hovering
            if !hovering { copiedCommand = nil }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: checklist)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("CloudGettingStartedCard")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            if checklist.isComplete {
                // Quiet: the accent check, not a celebration.
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
            // The strongest text on the card: primary and semibold, a step
            // above the step titles (Cursor's card leads with its title).
            Text(checklist.isComplete ? CloudGettingStartedChecklist.completedTitle : Self.title)
                .cmuxFont(size: 12.5, weight: .semibold)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("CloudGettingStartedTitle")
            Spacer(minLength: 4)
            if !checklist.isComplete {
                Text(progressLabel)
                    .cmuxFont(size: 11, monospacedDigit: true)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(progressAccessibilityLabel)
                progressRing
            }
            // Hover-only close, like a footer nudge: present when wanted,
            // invisible otherwise. Its slot is kept so the count never jumps.
            CloudBannerDismissButton(action: actions.dismiss)
                .opacity(isHovered ? 1 : 0)
                .accessibilityIdentifier("CloudGettingStartedDismissButton")
        }
        .frame(height: 20)
    }

    static var title: String {
        String(localized: "cloud.gettingStarted.title", defaultValue: "Get started with cmux Cloud")
    }

    /// The finished card: one secondary line under "You're set up".
    private var completedBody: some View {
        Text(CloudGettingStartedChecklist.completedDetail)
            .cmuxFont(size: 11)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 18)
            .accessibilityIdentifier("CloudGettingStartedCompleted")
    }

    private var progressLabel: String {
        String(
            format: String(localized: "cloud.gettingStarted.progress", defaultValue: "%1$ld/%2$ld"),
            checklist.completedCount,
            checklist.totalCount
        )
    }

    private var progressAccessibilityLabel: String {
        String(
            format: String(
                localized: "cloud.gettingStarted.progress.accessibility",
                defaultValue: "%1$ld of %2$ld steps done"
            ),
            checklist.completedCount,
            checklist.totalCount
        )
    }

    private var progressRing: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.12), lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: max(0.001, checklist.progress))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 11, height: 11)
        .accessibilityHidden(true)
    }

    // MARK: Steps

    @ViewBuilder
    private func stepRow(_ step: CloudGettingStartedChecklist.Step) -> some View {
        let isCurrent = checklist.current == step
        let isDone = checklist.isDone(step)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                stepMark(isDone: isDone, isCurrent: isCurrent)
                Text(step.title)
                    .cmuxFont(size: 12, weight: isCurrent ? .medium : .regular)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(HierarchicalShapeStyle.primary) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                    .strikethrough(isDone, color: Color.secondary.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if isCurrent {
                currentStepBody(step)
                    .padding(.leading, 21)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(stepAccessibilityLabel(step, isDone: isDone))
        .accessibilityIdentifier(step.accessibilityIdentifier)
    }

    private func stepAccessibilityLabel(_ step: CloudGettingStartedChecklist.Step, isDone: Bool) -> String {
        guard isDone else { return step.title }
        return String(
            format: String(localized: "cloud.gettingStarted.step.done.accessibility", defaultValue: "%@, done"),
            step.title
        )
    }

    private func stepMark(isDone: Bool, isCurrent: Bool) -> some View {
        ZStack {
            if isDone {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
            } else {
                Circle()
                    .strokeBorder(
                        isCurrent ? Color.accentColor : Color.secondary.opacity(0.45),
                        lineWidth: 1.25
                    )
                    .frame(width: 12, height: 12)
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }

    /// One line of why, one compact action, and a subtle "Learn more" on
    /// the action's line. The action hugs its label: the card is a nudge
    /// beside the tree, not a call to action that outweighs its title.
    @ViewBuilder
    private func currentStepBody(_ step: CloudGettingStartedChecklist.Step) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(step.detail)
                .cmuxFont(size: 11)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            switch step {
            case .addKeys:
                if let openSecrets = actions.openSecrets {
                    actionLine(step) {
                        compactButton(
                            String(localized: "cloud.gettingStarted.keys.action", defaultValue: "Add API Keys…"),
                            identifier: "CloudGettingStartedAddKeysButton",
                            action: openSecrets
                        )
                    }
                } else {
                    commandRow(CloudGettingStartedChecklist.importKeysCommand)
                    actionLine(step) { EmptyView() }
                }
            case .createMachine:
                actionLine(step) {
                    compactButton(
                        String(localized: "cloudTree.action.newCloudMachine", defaultValue: "New Cloud Machine"),
                        identifier: "CloudGettingStartedNewMachineButton",
                        action: actions.createMachine
                    )
                }
            case .startAgent:
                commandRow(CloudGettingStartedChecklist.startAgentCommand())
                actionLine(step) {
                    if let openLocalAgent = actions.openLocalAgent {
                        quietButton(
                            String(
                                localized: "cloud.gettingStarted.agent.askClaude",
                                defaultValue: "Ask Claude Code Instead"
                            ),
                            help: String(
                                localized: "cloud.gettingStarted.agent.askClaude.help",
                                defaultValue: "Opens Claude Code on this Mac with the cmux Cloud skill, so it can start agents on your machines for you."
                            ),
                            identifier: "CloudGettingStartedAskClaudeButton",
                            action: openLocalAgent
                        )
                    }
                }
            }
        }
    }

    /// The step's control followed by "Learn more", on one line.
    private func actionLine<Control: View>(
        _ step: CloudGettingStartedChecklist.Step,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 10) {
            control()
            Link(String(localized: "cloud.security.learnMore", defaultValue: "Learn more"), destination: step.learnMoreURL)
                .cmuxFont(size: 11)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("\(step.accessibilityIdentifier).learnMore")
            Spacer(minLength: 0)
        }
    }

    // MARK: Controls

    /// The one-surface shortcut through every step: key, machine and agent
    /// in parallel (``CloudFirstRunSheet``). A quiet accent line under the
    /// steps, so the checklist stays the card's structure.
    private func allAtOnceButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9, weight: .semibold))
                Text(String(localized: "cloud.gettingStarted.allAtOnce", defaultValue: "Do all three at once\u{2026}"))
                    .cmuxFont(size: 11, weight: .medium)
            }
            .foregroundStyle(Color.accentColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(
            localized: "cloud.gettingStarted.allAtOnce.help",
            defaultValue: "Starts a machine, checks your key and starts an agent on a repository, usually in under a minute."
        ))
        .padding(.leading, 21)
        .padding(.top, 6)
        .accessibilityIdentifier("CloudGettingStartedAllAtOnceButton")
    }

    /// A small bordered button sized to its label (Cursor's neutral fill).
    private func compactButton(_ title: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .cmuxFont(size: 11.5, weight: .medium)
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier(identifier)
    }

    /// A text-weight alternative next to "Learn more".
    private func quietButton(_ title: String, help: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .cmuxFont(size: 11)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityIdentifier(identifier)
    }

    /// The command in a monospace well with a copy button. The check stays
    /// until the pointer leaves the card, so no timer is needed to reset it.
    private func commandRow(_ command: String) -> some View {
        let copied = copiedCommand == command
        let copyTitle = copied
            ? String(localized: "cloud.gettingStarted.copied", defaultValue: "Copied")
            : String(localized: "cloud.gettingStarted.copy", defaultValue: "Copy Command")
        return HStack(spacing: 6) {
            Text(command)
                .cmuxFont(size: 11, design: .monospaced)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(command, forType: .string)
                copiedCommand = command
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(copied ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(copyTitle)
            .accessibilityLabel(copyTitle)
            .accessibilityIdentifier("CloudGettingStartedCopyCommandButton")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }
}
