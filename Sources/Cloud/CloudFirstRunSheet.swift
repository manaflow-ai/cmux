import AppKit
import CmuxFoundation
import SwiftUI

/// What the tour's links and recoveries do outside the model.
struct CloudFirstRunSheetActions {
    /// Closes the tour. While a run is in flight it keeps going and the agent
    /// still opens; the machine keeps starting either way.
    var close: () -> Void
    /// Signs the agent in with the person's subscription (CodeRouter), in a
    /// terminal; the tour hides and resumes when reopened.
    var addSubscription: ((CloudFirstRunAgent) -> Void)?
    /// Opens Cloud Secrets (a private repository needs GH_TOKEN).
    var openSecrets: () -> Void
}

/// "Start your first cloud agent": one compact surface, not a wizard. The
/// three steps sit in one list and run side by side: the key step checks
/// itself, the machine is already starting when the surface appears, and the
/// last step is a small composer (repository, first task, agent). A live
/// timer runs from open to a running agent; each finished step keeps its
/// check and how long it took.
struct CloudFirstRunSheet: View {
    @Bindable var model: CloudFirstRunModel
    let actions: CloudFirstRunSheetActions

    @FocusState private var focus: Field?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Field: Hashable {
        case key
        case repo
        case prompt
    }

    static let width: CGFloat = 500

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 16)
            VStack(alignment: .leading, spacing: 14) {
                stepRow(.key) { keyBody }
                stepRow(.machine) { EmptyView() }
                stepRow(.agent) { composer }
            }
            footer
                .padding(.top, 18)
        }
        .padding(20)
        .frame(width: Self.width, alignment: .leading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.keySource)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.run)
        .onAppear {
            focus = model.keySource == .missing ? .key : .repo
        }
        .onChange(of: model.keyFocusRequest) { _, _ in focus = .key }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("CloudFirstRunSheet")
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "cloud.firstRun.title", defaultValue: "Start your first cloud agent"))
                    .cmuxFont(size: 15, weight: .semibold)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                timer
            }
            Text(String(
                localized: "cloud.firstRun.subtitle",
                defaultValue: "An agent on a Cloud machine, with your keys, working on a repository. Usually under a minute."
            ))
            .cmuxFont(size: 12)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// m:ss from open until the agent runs, then frozen in the accent color.
    private var timer: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = model.timeline.elapsed(now: context.date)
            Text(CloudFirstRunTimeline.clock(seconds))
                .cmuxFont(size: 12, weight: .medium, monospacedDigit: true)
                .foregroundStyle(model.timeline.isFinished ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                .accessibilityLabel(String(
                    format: String(localized: "cloud.firstRun.timer.accessibility", defaultValue: "%@ elapsed"),
                    CloudFirstRunTimeline.clock(seconds)
                ))
                .accessibilityIdentifier("CloudFirstRunTimer")
        }
    }

    // MARK: Steps

    private func stepRow<Body: View>(
        _ step: CloudFirstRunModel.Step,
        @ViewBuilder body: () -> Body
    ) -> some View {
        let state = model.state(of: step)
        return HStack(alignment: .top, spacing: 10) {
            CloudFirstRunStepMark(state: state, number: (CloudFirstRunModel.Step.allCases.firstIndex(of: step) ?? 0) + 1)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title(of: step))
                        .cmuxFont(size: 12.5, weight: .medium)
                        .foregroundStyle(.primary)
                    Text(detail(of: step, state: state))
                        .cmuxFont(size: 12)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let seconds = duration(of: step, state: state) {
                        Text(CloudFirstRunTimeline.duration(seconds))
                            .cmuxFont(size: 11, monospacedDigit: true)
                            .foregroundStyle(.tertiary)
                    }
                }
                if case .failed(let failure) = state {
                    failureLine(failure)
                }
                body()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("CloudFirstRun.\(step.rawValue)")
    }

    private func title(of step: CloudFirstRunModel.Step) -> String {
        switch step {
        case .key:
            return String(localized: "cloud.firstRun.step.key", defaultValue: "Key")
        case .machine:
            return String(localized: "cloud.firstRun.step.machine", defaultValue: "Machine")
        case .agent:
            return String(localized: "cloud.firstRun.step.agent", defaultValue: "Repository and task")
        }
    }

    private func detail(of step: CloudFirstRunModel.Step, state: CloudFirstRunModel.StepState) -> String {
        switch step {
        case .key:
            switch model.keySource {
            case .vault(let name):
                return String(
                    format: String(localized: "cloud.firstRun.key.vault", defaultValue: "%@ from Cloud Secrets"),
                    name
                )
            case .teamRouter:
                return String(
                    format: String(localized: "cloud.firstRun.key.team", defaultValue: "Your team\u{2019}s %@ account, no key needed"),
                    model.agent == .claude ? "Claude" : "Codex"
                )
            case .typed:
                return String(localized: "cloud.firstRun.key.typed", defaultValue: "Saved when you start")
            case .missing:
                return String(
                    format: String(localized: "cloud.firstRun.key.missing", defaultValue: "%@ needs a key"),
                    model.agent.displayName
                )
            }
        case .machine:
            switch model.machine {
            case .looking:
                return String(localized: "cloud.firstRun.machine.looking", defaultValue: "Looking for a running machine\u{2026}")
            case .starting:
                return String(localized: "cloud.firstRun.machine.starting", defaultValue: "Starting a machine\u{2026}")
            case .ready(let machine) where machine.needsWake:
                return String(
                    format: String(localized: "cloud.firstRun.machine.wakes", defaultValue: "%@, wakes when you start"),
                    machine.name
                )
            case .ready(let machine):
                return machine.name
            case .failed:
                return String(localized: "cloud.firstRun.machine.failed", defaultValue: "Didn\u{2019}t start")
            }
        case .agent:
            switch model.run {
            case .editing, .failed:
                return ""
            case .savingKey:
                return String(localized: "cloud.firstRun.run.savingKey", defaultValue: "Saving your key\u{2026}")
            case .waitingForMachine:
                return String(localized: "cloud.firstRun.run.waiting", defaultValue: "Waiting for the machine\u{2026}")
            case .cloning:
                return model.progress.detail(repo: model.repoDisplayName ?? "", agent: model.agent)
            case .started:
                return String(
                    format: String(localized: "cloud.firstRun.run.started", defaultValue: "%@ is running"),
                    model.agent.displayName
                )
            }
        }
    }

    private func duration(of step: CloudFirstRunModel.Step, state: CloudFirstRunModel.StepState) -> Double? {
        guard state == .done else { return nil }
        switch step {
        case .key: return nil
        case .machine: return model.timeline.seconds(.machineReady)
        case .agent: return model.timeline.seconds(.agentStarted)
        }
    }

    /// One line of reason and its one recovery: never a dead end.
    private func failureLine(_ failure: CloudFirstRunFailure) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(failure.reason)
                .cmuxFont(size: 11.5)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            Button(failure.recovery.title) { recover(failure.recovery) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("CloudFirstRunRecoveryButton")
        }
    }

    private func recover(_ recovery: CloudFirstRunRecovery) {
        if !model.perform(recovery), recovery == .addGitHubToken {
            actions.openSecrets()
        }
    }

    // MARK: Key

    @ViewBuilder
    private var keyBody: some View {
        if model.keySource == .missing || model.keySource == .typed {
            VStack(alignment: .leading, spacing: 6) {
                SecureField(
                    String(
                        format: String(localized: "cloud.firstRun.key.placeholder", defaultValue: "Paste your %@"),
                        model.agent.savedKeyName
                    ),
                    text: $model.typedKey
                )
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .key)
                .disabled(model.run.isBusy)
                .accessibilityIdentifier("CloudFirstRunKeyField")
                HStack(spacing: 12) {
                    Link(model.agent.getKeyLabel, destination: model.agent.keyURL)
                        .cmuxFont(size: 11)
                    if let addSubscription = actions.addSubscription {
                        Button(model.agent.subscriptionLabel) { addSubscription(model.agent) }
                            .buttonStyle(.plain)
                            .cmuxFont(size: 11)
                            .foregroundStyle(.secondary)
                            .help(String(
                                localized: "cloud.firstRun.key.subscription.help",
                                defaultValue: "Opens a terminal to connect your subscription to cmux. Come back here when it finishes."
                            ))
                            .accessibilityIdentifier("CloudFirstRunSubscriptionButton")
                    }
                    Spacer(minLength: 0)
                }
                Text(String(
                    localized: "cloud.firstRun.key.privacy",
                    defaultValue: "Stored in Cloud Secrets on this Mac and sent to your machines end to end."
                ))
                .cmuxFont(size: 11)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .transition(.opacity)
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField(
                    String(localized: "cloud.firstRun.repo.placeholder", defaultValue: "owner/repo or a GitHub URL"),
                    text: $model.repoText
                )
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .repo)
                .accessibilityIdentifier("CloudFirstRunRepoField")
                Button {
                    model.useSampleRepo()
                    focus = .prompt
                } label: {
                    Label(
                        String(localized: "cloud.firstRun.repo.sample", defaultValue: "Try a Sample"),
                        systemImage: model.isSampleRepo ? "checkmark" : "sparkles"
                    )
                    .cmuxFont(size: 11.5)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule(style: .continuous).fill(Color.primary.opacity(model.isSampleRepo ? 0.1 : 0.06)))
                }
                .buttonStyle(.plain)
                .help(String(
                    format: String(localized: "cloud.firstRun.repo.sample.help", defaultValue: "%@, a tiny public repository"),
                    CloudFirstRunRepo.sample
                ))
                .accessibilityIdentifier("CloudFirstRunSampleRepoButton")
            }
            .disabled(model.run.isBusy)
            if !model.repoText.trimmingCharacters(in: .whitespaces).isEmpty, model.repoReference == nil {
                Text(String(
                    localized: "cloud.firstRun.repo.invalid",
                    defaultValue: "Use owner/repo, a GitHub URL or a git@ address."
                ))
                .cmuxFont(size: 11)
                .foregroundStyle(.secondary)
            }
            promptWell
        }
    }

    /// The first task in a composer well, with the agent picker in its
    /// bottom bar (the controls sit where the task is written).
    private var promptWell: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(
                String(localized: "cloud.firstRun.prompt.placeholder", defaultValue: "What should the agent do first?"),
                text: $model.prompt,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .cmuxFont(size: 12.5)
            .lineLimit(2...5)
            .focused($focus, equals: .prompt)
            .accessibilityIdentifier("CloudFirstRunPromptField")
            HStack(spacing: 6) {
                Menu {
                    Picker(selection: $model.agent) {
                        ForEach(CloudFirstRunAgent.allCases, id: \.self) { agent in
                            Text(agent.displayName).tag(agent)
                        }
                    } label: { EmptyView() }
                    .pickerStyle(.inline)
                } label: {
                    Label(model.agent.displayName, systemImage: "sparkle")
                        .cmuxFont(size: 11.5)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityIdentifier("CloudFirstRunAgentPicker")
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(focus == .prompt ? 0.22 : 0.1), lineWidth: 0.5)
        )
        .disabled(model.run.isBusy)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Link(String(localized: "cloud.security.learnMore", defaultValue: "Learn more"), destination: CloudDocsLinks.openRepo)
                .cmuxFont(size: 11)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(model.run.isBusy
                   ? String(localized: "cloud.firstRun.hide", defaultValue: "Hide")
                   : String(localized: "common.cancel", defaultValue: "Cancel")) {
                actions.close()
            }
            .keyboardShortcut(.cancelAction)
            .help(cancelHelp)
            .accessibilityIdentifier("CloudFirstRunCancelButton")
            Button {
                model.go()
            } label: {
                HStack(spacing: 6) {
                    if model.run.isBusy {
                        ProgressView().controlSize(.small)
                    }
                    Text(model.run.isBusy
                         ? String(localized: "cloud.firstRun.go.busy", defaultValue: "Starting\u{2026}")
                         : String(localized: "cloud.firstRun.go", defaultValue: "Start Agent"))
                }
            }
            .keyboardShortcut(.defaultAction)
            .cloudProminentButtonStyle()
            .disabled(!model.canGo)
            .accessibilityIdentifier("CloudFirstRunGoButton")
        }
    }
}

extension CloudFirstRunSheet {
    /// One line on what Cancel does to the machine: Hide keeps it for the
    /// run; before Go, a machine this tour started is deleted with the tour.
    var cancelHelp: String {
        if model.run.isBusy {
            return String(
                localized: "cloud.firstRun.hide.help",
                defaultValue: "The agent keeps starting and opens when it is ready."
            )
        }
        if model.cancelDeletesMachine {
            return String(
                localized: "cloud.firstRun.cancel.deletesMachine.help",
                defaultValue: "Cancel and delete the machine this started (nothing was set up on it yet)."
            )
        }
        return String(localized: "cloud.firstRun.cancel.help", defaultValue: "Close without starting an agent.")
    }
}

/// A step's mark: its number while waiting, a spinner while working, the
/// accent check when done, an amber triangle when it needs the person.
private struct CloudFirstRunStepMark: View {
    let state: CloudFirstRunModel.StepState
    let number: Int

    var body: some View {
        ZStack {
            switch state {
            case .waiting:
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1.25)
                Text(verbatim: String(number))
                    .cmuxFont(size: 10, weight: .semibold, monospacedDigit: true)
                    .foregroundStyle(.secondary)
            case .working:
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.8)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.accentColor)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}
