#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct NotificationFeedPermissionControls: View {
    let item: MobileNotificationFeedItem
    let design: MobileNotificationFeedDesign
    let action: @MainActor @Sendable (MobileNotificationFeedItem, MobileFeedPermissionMode) async -> Bool

    @State private var pendingMode: MobileFeedPermissionMode?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NotificationFeedDecisionCaption(
                title: L10n.string("mobile.notificationFeed.permission.caption", defaultValue: "Permission required"),
                design: design
            )
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(MobileFeedPermissionMode.allCases, id: \.rawValue) { mode in
                        Button(mode.localizedFeedLabel) { submit(mode) }
                            .buttonStyle(.bordered)
                            .tint(mode == .deny ? .red : .accentColor)
                            .disabled(pendingMode != nil)
                            .accessibilityIdentifier("MobileNotificationFeedPermission-\(mode.rawValue)")
                    }
                }
            }
            NotificationFeedDecisionFailure(failed: failed)
        }
    }

    private func submit(_ mode: MobileFeedPermissionMode) {
        guard pendingMode == nil else { return }
        pendingMode = mode
        failed = false
        Task { @MainActor in
            let delivered = await action(item, mode)
            failed = !delivered
            pendingMode = nil
        }
    }
}

struct NotificationFeedExitPlanControls: View {
    let item: MobileNotificationFeedItem
    let design: MobileNotificationFeedDesign
    let defaultMode: MobileFeedExitPlanMode
    let action: @MainActor @Sendable (MobileNotificationFeedItem, MobileFeedExitPlanMode, String?) async -> Bool

    @State private var selectedMode: MobileFeedExitPlanMode
    @State private var feedback = ""
    @State private var isSending = false
    @State private var failed = false

    init(
        item: MobileNotificationFeedItem,
        design: MobileNotificationFeedDesign,
        defaultMode: MobileFeedExitPlanMode,
        action: @escaping @MainActor @Sendable (MobileNotificationFeedItem, MobileFeedExitPlanMode, String?) async -> Bool
    ) {
        self.item = item
        self.design = design
        self.defaultMode = defaultMode
        self.action = action
        _selectedMode = State(initialValue: defaultMode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            NotificationFeedDecisionCaption(
                title: L10n.string("mobile.notificationFeed.exitPlan.caption", defaultValue: "Plan ready"),
                design: design
            )
            Picker(
                L10n.string("mobile.notificationFeed.exitPlan.mode", defaultValue: "Run mode"),
                selection: $selectedMode
            ) {
                ForEach(MobileFeedExitPlanMode.allCases, id: \.rawValue) { mode in
                    Text(mode.localizedFeedLabel).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("MobileNotificationFeedExitPlanMode")
            TextField(
                L10n.string(
                    "mobile.notificationFeed.exitPlan.feedback",
                    defaultValue: "Tell the agent what to change (optional)"
                ),
                text: $feedback,
                axis: .vertical
            )
            .lineLimit(1...4)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("MobileNotificationFeedExitPlanFeedback")
            Button {
                submit()
            } label: {
                if isSending {
                    ProgressView()
                } else {
                    Label(
                        L10n.string("mobile.notificationFeed.exitPlan.submit", defaultValue: "Submit Plan Decision"),
                        systemImage: "checkmark.circle.fill"
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSending)
            .accessibilityIdentifier("MobileNotificationFeedExitPlanSubmit")
            NotificationFeedDecisionFailure(failed: failed)
        }
    }

    private func submit() {
        guard !isSending else { return }
        isSending = true
        failed = false
        let text = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            let delivered = await action(item, selectedMode, text.isEmpty ? nil : text)
            failed = !delivered
            isSending = false
        }
    }
}

struct NotificationFeedQuestionControls: View {
    let item: MobileNotificationFeedItem
    let design: MobileNotificationFeedDesign
    let prompts: [MobileFeedQuestionPrompt]
    let action: @MainActor @Sendable (MobileNotificationFeedItem, [String]) async -> Bool

    @State private var selections: [Int: Set<String>] = [:]
    @State private var customAnswers: [Int: String] = [:]
    @State private var isSending = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NotificationFeedDecisionCaption(
                title: L10n.string("mobile.notificationFeed.question.caption", defaultValue: "Agent question"),
                design: design
            )
            ForEach(Array(prompts.enumerated()), id: \.offset) { index, prompt in
                VStack(alignment: .leading, spacing: 6) {
                    if let header = prompt.header, !header.isEmpty {
                        Text(header).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Text(prompt.prompt).font(.subheadline.weight(.medium))
                    if prompt.allowsMultipleSelections {
                        Text(L10n.string("mobile.notificationFeed.question.multiSelect", defaultValue: "Select all that apply"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if !prompt.options.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(prompt.options) { option in
                                    Button {
                                        toggle(option.id, at: index, allowsMultiple: prompt.allowsMultipleSelections)
                                    } label: {
                                        HStack(alignment: .top, spacing: 6) {
                                            Image(systemName: selections[index]?.contains(option.id) == true
                                                ? "checkmark.circle.fill" : "circle")
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(option.label)
                                                if let detail = option.detail, !detail.isEmpty {
                                                    Text(detail)
                                                        .font(.caption2)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier(
                                        "MobileNotificationFeedQuestionOption-\(index)-\(option.id)"
                                    )
                                }
                            }
                        }
                    }
                    TextField(
                        L10n.string("mobile.notificationFeed.question.custom", defaultValue: "Type another answer"),
                        text: customAnswerBinding(at: index),
                        axis: .vertical
                    )
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("MobileNotificationFeedQuestionCustom-\(index)")
                }
                .padding(8)
                .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            }
            Button {
                submit()
            } label: {
                if isSending {
                    ProgressView()
                } else {
                    Label(
                        L10n.string("mobile.notificationFeed.question.submit", defaultValue: "Submit Answers"),
                        systemImage: "paperplane.fill"
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSending || !canSubmit)
            .accessibilityIdentifier("MobileNotificationFeedQuestionSubmit")
            NotificationFeedDecisionFailure(failed: failed)
        }
    }

    private var answers: [String] {
        prompts.enumerated().map { index, prompt in
            let custom = (customAnswers[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !custom.isEmpty { return custom }
            let selected = selections[index] ?? []
            let labels = prompt.options.filter { selected.contains($0.id) }.map(\.label)
            return labels.joined(separator: ", ")
        }
    }

    private var canSubmit: Bool {
        !prompts.isEmpty && answers.allSatisfy { !$0.isEmpty }
    }

    private func toggle(_ id: String, at index: Int, allowsMultiple: Bool) {
        var current = selections[index] ?? []
        if allowsMultiple {
            if current.remove(id) == nil { current.insert(id) }
        } else {
            current = [id]
        }
        selections[index] = current
    }

    private func customAnswerBinding(at index: Int) -> Binding<String> {
        Binding(get: { customAnswers[index] ?? "" }, set: { customAnswers[index] = $0 })
    }

    private func submit() {
        guard canSubmit, !isSending else { return }
        isSending = true
        failed = false
        let submittedAnswers = answers
        Task { @MainActor in
            let delivered = await action(item, submittedAnswers)
            failed = !delivered
            isSending = false
        }
    }
}

private struct NotificationFeedDecisionCaption: View {
    let title: String
    let design: MobileNotificationFeedDesign

    var body: some View {
        Label(title, systemImage: design == .commandCenter ? "bolt.fill" : "hand.tap.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(design == .commandCenter ? .orange : .secondary)
    }
}

private struct NotificationFeedDecisionFailure: View {
    let failed: Bool

    var body: some View {
        if failed {
            Text(L10n.string(
                "mobile.notificationFeed.decision.failed",
                defaultValue: "The decision wasn't delivered. Check the Mac connection and try again."
            ))
            .font(.caption)
            .foregroundStyle(.red)
        }
    }
}

private extension MobileFeedPermissionMode {
    var localizedFeedLabel: String {
        switch self {
        case .once: L10n.string("mobile.notificationFeed.permission.once", defaultValue: "Allow Once")
        case .always: L10n.string("mobile.notificationFeed.permission.always", defaultValue: "Always Allow")
        case .all: L10n.string("mobile.notificationFeed.permission.all", defaultValue: "Allow All")
        case .bypass: L10n.string("mobile.notificationFeed.permission.bypass", defaultValue: "Bypass")
        case .deny: L10n.string("mobile.notificationFeed.permission.deny", defaultValue: "Deny")
        }
    }
}

private extension MobileFeedExitPlanMode {
    var localizedFeedLabel: String {
        switch self {
        case .ultraplan: L10n.string("mobile.notificationFeed.exitPlan.ultraplan", defaultValue: "Ultraplan")
        case .bypassPermissions: L10n.string("mobile.notificationFeed.exitPlan.bypass", defaultValue: "Bypass Permissions")
        case .autoAccept: L10n.string("mobile.notificationFeed.exitPlan.autoAccept", defaultValue: "Auto Accept")
        case .manual: L10n.string("mobile.notificationFeed.exitPlan.manual", defaultValue: "Manual")
        case .deny: L10n.string("mobile.notificationFeed.exitPlan.deny", defaultValue: "Reject")
        }
    }
}
#endif
