import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

/// The work-order composer: one document with every input visible — brief,
/// project, agent — a perforated tear line, and the dispatch stub. Launch
/// verdicts are stamped straight onto the stub.
struct DispatchDocumentScreen: View {
    @Bindable var model: DispatchComposerModel
    let openProjectPicker: () -> Void
    let cancel: () -> Void
    /// Called after the DISPATCHED stamp has landed; owner dismisses the sheet.
    let finished: () -> Void

    @FocusState private var briefFocused: Bool

    private var isConnected: Bool { model.service.dispatchIsConnected }

    private var isLaunching: Bool { model.launchState == .launching }
    private var isDispatched: Bool { model.launchState == .dispatched }

    private var rejection: DispatchLaunchFailure? {
        if case let .rejected(failure) = model.launchState { return failure }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if !isConnected {
                    offlineRibbon
                }
                documentCard
                Text(hintText)
                    .font(DispatchStyle.monoCaptionFont)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(DispatchStyle.screenBackground)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(action: cancel) {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel(L10n.string("mobile.dispatch.cancel", defaultValue: "Close"))
                .accessibilityIdentifier("MobileDispatchCancel")
            }
            ToolbarItem(placement: .principal) {
                Text(L10n.string("mobile.dispatch.title", defaultValue: "New Dispatch"))
                    .font(DispatchStyle.fieldLabelFont)
                    .tracking(DispatchStyle.fieldLabelTracking)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            model.loadCatalogIfNeeded()
            briefFocused = true
        }
        .sensoryFeedback(trigger: model.launchState) { _, new in
            switch new {
            case .dispatched: return .success
            case .rejected: return .error
            default: return nil
            }
        }
        .sensoryFeedback(.warning, trigger: model.validationNudgeGeneration)
        .task(id: isDispatched) {
            guard isDispatched else { return }
            // Let the DISPATCHED stamp land before sliding into the workspace.
            try? await ContinuousClock().sleep(for: .milliseconds(850))
            guard !Task.isCancelled else { return }
            finished()
        }
    }

    private var hintText: String {
        let host = model.service.dispatchHostName
        if let host, !host.isEmpty {
            return String(
                format: L10n.string(
                    "mobile.dispatch.hint.format",
                    defaultValue: "Runs in a new workspace on %@."
                ),
                host
            )
        }
        return L10n.string("mobile.dispatch.hint", defaultValue: "Runs in a new workspace on your Mac.")
    }

    private var offlineRibbon: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(.orange)
            Text(L10n.string(
                "mobile.dispatch.offline",
                defaultValue: "Mac offline. Reconnecting…"
            ))
            .font(DispatchStyle.monoCaptionFont)
        }
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .accessibilityIdentifier("MobileDispatchOfflineRibbon")
    }

    // MARK: - Document

    private var documentCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, DispatchStyle.cardPadding)
                .padding(.top, DispatchStyle.cardPadding)
                .padding(.bottom, 14)
            cardRule
            briefSection
                .padding(.horizontal, DispatchStyle.cardPadding)
                .padding(.vertical, 16)
            cardRule
            projectSection
                .padding(.horizontal, DispatchStyle.cardPadding)
                .padding(.vertical, 16)
            cardRule
            agentSection
                .padding(.horizontal, DispatchStyle.cardPadding)
                .padding(.vertical, 16)
            DispatchPerforationDivider()
            stubSection
                .padding(.horizontal, DispatchStyle.cardPadding)
                .padding(.top, 10)
                .padding(.bottom, DispatchStyle.cardPadding)
        }
        .background(
            RoundedRectangle(cornerRadius: DispatchStyle.cardCornerRadius, style: .continuous)
                .fill(DispatchStyle.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DispatchStyle.cardCornerRadius, style: .continuous)
                .stroke(DispatchStyle.hairline, lineWidth: 0.5)
        )
    }

    private var cardRule: some View {
        Rectangle()
            .fill(DispatchStyle.hairline)
            .frame(height: 0.5)
            .padding(.horizontal, DispatchStyle.cardPadding)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(headerTitle)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            Text(String(format: L10n.string(
                "mobile.dispatch.serial.format",
                defaultValue: "Nº %04d"
            ), model.serial))
                .foregroundStyle(.secondary)
                .layoutPriority(1)
        }
        .font(DispatchStyle.fieldLabelFont)
        .tracking(DispatchStyle.fieldLabelTracking)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("MobileDispatchHeader")
    }

    private var headerTitle: String {
        let word = L10n.string("mobile.dispatch.header", defaultValue: "Dispatch").uppercased()
        if let host = model.service.dispatchHostName, !host.isEmpty {
            return "\(word) / \(host.uppercased())"
        }
        return word
    }

    private func fieldLabel(_ text: String, alerting: Bool) -> some View {
        Text(text)
            .font(DispatchStyle.fieldLabelFont)
            .tracking(DispatchStyle.fieldLabelTracking)
            .textCase(.uppercase)
            .foregroundStyle(alerting ? AnyShapeStyle(DispatchStyle.stampRejected) : AnyShapeStyle(.tertiary))
    }

    // MARK: - Brief

    private var briefNudged: Bool { model.validationNudge == .brief }

    private var briefSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                fieldLabel(
                    L10n.string("mobile.dispatch.field.brief", defaultValue: "Brief"),
                    alerting: briefNudged || model.isOverBudget
                )
                Spacer()
                if model.showsBudgetCounter {
                    Text(String(format: L10n.string(
                        "mobile.dispatch.budget.format",
                        defaultValue: "%1$d / %2$d"
                    ), model.briefByteCount, model.promptByteBudget))
                        .font(DispatchStyle.monoCaptionFont)
                        .foregroundStyle(model.isOverBudget ? AnyShapeStyle(DispatchStyle.stampRejected) : AnyShapeStyle(.secondary))
                        .accessibilityIdentifier("MobileDispatchBudgetCounter")
                }
            }
            TextField(
                L10n.string("mobile.dispatch.brief.placeholder", defaultValue: "What should get done?"),
                text: $model.brief,
                axis: .vertical
            )
            .font(.body)
            .lineLimit(4 ... 12)
            .focused($briefFocused)
            .accessibilityIdentifier("MobileDispatchBriefEditor")
            if briefNudged {
                Text(briefNudgeText)
                    .font(.caption2)
                    .foregroundStyle(DispatchStyle.stampRejected)
            }
        }
        .modifier(DispatchShakeEffect(
            animatableData: briefNudged ? CGFloat(model.validationNudgeGeneration) : 0
        ))
        .animation(.linear(duration: 0.3), value: model.validationNudgeGeneration)
    }

    private var briefNudgeText: String {
        if model.isOverBudget {
            return String(format: L10n.string(
                "mobile.dispatch.brief.overBudget",
                defaultValue: "The brief is over the %d-byte dispatch limit."
            ), model.promptByteBudget)
        }
        return L10n.string("mobile.dispatch.brief.empty", defaultValue: "Write the brief first.")
    }

    // MARK: - Project

    private var projectSection: some View {
        Button(action: openProjectPicker) {
            VStack(alignment: .leading, spacing: 10) {
                fieldLabel(L10n.string("mobile.dispatch.field.project", defaultValue: "Project"), alerting: false)
                HStack(spacing: 8) {
                    Text(projectDisplayText)
                        .font(DispatchStyle.monoValueFont)
                        .foregroundStyle(model.directoryPath == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("MobileDispatchProjectRow")
    }

    private var projectDisplayText: String {
        if let path = model.directoryPath {
            return model.displayPath(path)
        }
        if case .loading = model.catalogState {
            return L10n.string("mobile.dispatch.project.loading", defaultValue: "Loading folders…")
        }
        return L10n.string("mobile.dispatch.project.choose", defaultValue: "Choose a folder")
    }

    // MARK: - Agent

    private var agentNudged: Bool { model.validationNudge == .agent }

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel(L10n.string("mobile.dispatch.field.agent", defaultValue: "Agent"), alerting: agentNudged)
            switch model.catalogState {
            case .loading:
                HStack(spacing: 8) {
                    agentSkeletonPill
                    agentSkeletonPill
                }
            case .failed:
                DispatchInlineNotice(
                    icon: "wifi.exclamationmark",
                    text: L10n.string(
                        "mobile.dispatch.catalog.failed",
                        defaultValue: "Couldn't load agents and folders from the Mac."
                    ),
                    actionTitle: L10n.string("mobile.dispatch.retry", defaultValue: "Retry"),
                    action: { model.retryCatalog() }
                )
            case .ready:
                if model.agents.isEmpty || !model.agents.contains(where: \.installed) {
                    DispatchInlineNotice(
                        icon: "exclamationmark.triangle",
                        text: L10n.string(
                            "mobile.dispatch.agents.none",
                            defaultValue: "No agents found on the Mac. Install the claude or codex CLI, then retry."
                        ),
                        actionTitle: L10n.string("mobile.dispatch.retry", defaultValue: "Retry"),
                        action: { model.retryCatalog() }
                    )
                } else {
                    agentPills
                }
            }
        }
        .modifier(DispatchShakeEffect(
            animatableData: agentNudged ? CGFloat(model.validationNudgeGeneration) : 0
        ))
        .animation(.linear(duration: 0.3), value: model.validationNudgeGeneration)
    }

    private var agentSkeletonPill: some View {
        Capsule()
            .fill(DispatchStyle.hairline.opacity(0.35))
            .frame(width: 104, height: 33)
    }

    private var agentPills: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(model.agents) { agent in
                    agentPill(agent)
                }
            }
            if let missing = missingAgentsText {
                Text(missing)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func agentPill(_ agent: DispatchAgent) -> some View {
        let selected = model.agentID == agent.id
        return Button {
            model.selectAgent(agent.id)
        } label: {
            Text(agent.name)
                .font(.system(.footnote, design: .monospaced).weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .foregroundStyle(
                    selected
                        ? AnyShapeStyle(DispatchStyle.inkReversed)
                        : (agent.installed ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                )
                .background(
                    Capsule().fill(selected ? DispatchStyle.ink : Color.clear)
                )
                .overlay(
                    Capsule().stroke(selected ? Color.clear : DispatchStyle.hairline, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!agent.installed)
        .accessibilityIdentifier("MobileDispatchAgentPill_\(agent.id)")
    }

    private var missingAgentsText: String? {
        let missing = model.agents.filter { !$0.installed }
        guard !missing.isEmpty else { return nil }
        let names = missing.map(\.name).joined(separator: ", ")
        return String(format: L10n.string(
            "mobile.dispatch.agents.notInstalled.format",
            defaultValue: "%@ (not installed on this Mac)"
        ), names)
    }

    // MARK: - Stub

    private var stubSection: some View {
        VStack(spacing: 12) {
            Text(summaryText)
                .font(DispatchStyle.monoCaptionFont)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity)
            launchButton
            if let rejection {
                Text(rejection.displayReason(agentName: model.selectedAgent?.name))
                    .font(.caption)
                    .foregroundStyle(DispatchStyle.stampRejected)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("MobileDispatchRejectionReason")
            }
        }
        .overlay {
            if isDispatched {
                DispatchStampView(verdict: .dispatched)
            } else if rejection != nil {
                DispatchStampView(verdict: .rejected)
                    .allowsHitTesting(false)
            }
        }
    }

    private var summaryText: String {
        let agent = model.selectedAgent?.name
            ?? L10n.string("mobile.dispatch.summary.noAgent", defaultValue: "no agent")
        let project = model.directoryPath.map { model.displayPath($0) }
            ?? L10n.string("mobile.dispatch.summary.noProject", defaultValue: "no folder")
        return "\(agent) · \(project)"
    }

    private var launchButton: some View {
        Button {
            briefFocused = false
            model.attemptDispatch()
        } label: {
            ZStack {
                Text(L10n.string("mobile.dispatch.launch", defaultValue: "Dispatch"))
                    .font(DispatchStyle.stubFont)
                    .tracking(3)
                    .textCase(.uppercase)
                    .opacity(isLaunching || isDispatched || rejection != nil ? 0 : 1)
                if isLaunching {
                    ProgressView()
                        .tint(DispatchStyle.inkReversed)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: DispatchStyle.stubButtonHeight)
            .foregroundStyle(DispatchStyle.inkReversed)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(DispatchStyle.ink)
                    .opacity(stubBackgroundOpacity)
            )
        }
        .buttonStyle(DispatchPressButtonStyle())
        .disabled(!isConnected || isLaunching || isDispatched)
        .accessibilityIdentifier("MobileDispatchLaunchButton")
    }

    /// The stub recedes while a verdict stamp sits on top of it, and while the
    /// Mac is offline (the ribbon explains why it's not tappable).
    private var stubBackgroundOpacity: Double {
        if isDispatched || rejection != nil { return 0.14 }
        return isConnected ? 1 : 0.35
    }
}

/// Slight press-down scale so the stub feels physical.
struct DispatchPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

/// Quiet inline notice used inside the document for recoverable problems
/// (catalog fetch failed, no agents installed). Keeps the error visible where
/// it applies instead of hiding it behind an alert.
struct DispatchInlineNotice: View {
    let icon: String
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DispatchStyle.hairline.opacity(0.18))
        )
    }
}
