#if os(iOS)
import CmuxConversation
import SwiftUI

struct ConversationComposerArea: View {
    @Bindable var model: ConversationModel
    private var canSend: Bool {
        !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.connectionState == .connected
            && !model.isSubmitting
    }

    private var draftPlaceholder: Text {
        if model.isRunning {
            return Text(ConversationL10n.value("conversation.follow_up", "Follow up"))
        }
        let provider = model.sessions.first(where: { $0.id == model.selectedSessionID })?.provider.displayName
            ?? ConversationL10n.value("conversation.cloud", "Cloud")
        return Text("conversation.work_on \(provider)", bundle: .module)
    }

    var body: some View {
        VStack(spacing: 8) {
            if let request = model.blockingRequest {
                ConversationRequestCard(request: request, model: model)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                HStack(alignment: .bottom, spacing: 9) {
                    TextEditor(text: Binding(get: { model.draft }, set: { model.updateDraft($0) }))
                        .font(.body)
                        .frame(minHeight: 44, maxHeight: 118)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .accessibilityIdentifier("ConversationComposerTextEditor")
                        .overlay(alignment: .topLeading) {
                            if model.draft.isEmpty {
                                draftPlaceholder
                                    .font(.body)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 13)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }

                    if model.isRunning && model.supportsStopping && model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button {
                            model.stop()
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.subheadline.weight(.bold))
                                .frame(width: 44, height: 44)
                                .background(.primary, in: Circle())
                                .foregroundStyle(.background)
                        }
                        .accessibilityLabel(ConversationL10n.value("conversation.stop", "Stop task"))
                        .accessibilityIdentifier("ConversationStopButton")
                    } else {
                        Button {
                            model.submitDraft()
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.subheadline.weight(.bold))
                                .frame(width: 44, height: 44)
                                .background(canSend ? Color.accentColor : Color(uiColor: .tertiarySystemFill), in: Circle())
                                .foregroundStyle(canSend ? Color.white : Color.secondary)
                        }
                        .disabled(!canSend)
                        // A context menu owns the long press. It prevents the
                        // primary Button action from firing when a user chooses
                        // Steer or Queue, while exposing both actions to VoiceOver.
                        .contextMenu {
                            if model.isRunning && model.supportsSteering {
                                Button(ConversationL10n.value("conversation.steer", "Steer"), systemImage: "arrow.turn.up.right") {
                                    model.steer()
                                }
                                .accessibilityIdentifier("ConversationSteerButton")
                            }
                            if model.isRunning && model.supportsQueueing {
                                Button(ConversationL10n.value("conversation.queue", "Queue"), systemImage: "text.badge.plus") {
                                    model.queueTurn()
                                }
                                .accessibilityIdentifier("ConversationQueueButton")
                            }
                        }
                        .accessibilityHint(model.isRunning && (model.supportsSteering || model.supportsQueueing)
                            ? ConversationL10n.value("conversation.send_working.hint", "Long press for Steer or Queue")
                            : "")
                        .accessibilityLabel(model.isRunning ? ConversationL10n.value("conversation.send_followup", "Send follow up") : ConversationL10n.value("conversation.send_message", "Send message"))
                        .accessibilityIdentifier("ConversationSendButton")
                    }
                }
            }
            HStack(spacing: 10) {
                Text(model.isRunning ? ConversationL10n.value("conversation.working", "Working") : ConversationL10n.value("conversation.ready", "Ready"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 6)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.bar)
        .animation(.snappy, value: model.blockingRequest?.id)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ConversationComposer")
    }
}

private struct ConversationRequestCard: View {
    let request: ConversationRequest
    @Bindable var model: ConversationModel
    @State private var selectedOptionID: String?
    @State private var customAnswer = ""
    @State private var allowSession = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let approval = request.approval {
                Label(ConversationL10n.value("conversation.approval_needed", "Approval needed"), systemImage: "hand.raised")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(approval.summary)
                    .font(.body.weight(.semibold))
                if let command = approval.command {
                    ConversationCodeBlock(text: command, label: ConversationL10n.value("conversation.command", "Command"))
                }
                if approval.supportsAlwaysAllow {
                    Toggle(ConversationL10n.value("conversation.always_approve", "Always approve for this task"), isOn: $allowSession)
                        .font(.subheadline)
                }
                HStack {
                    Button(ConversationL10n.value("conversation.deny", "Deny"), role: .cancel) { model.resolveApproval(request, decision: .deny) }
                    Spacer()
                    Button(ConversationL10n.value("conversation.approve", "Approve")) { model.resolveApproval(request, decision: allowSession ? .alwaysApprove : .approve) }
                        .buttonStyle(.borderedProminent)
                }
            } else if let question = request.question {
                ConversationQuestionCard(request: request, model: model, isBlocking: true)
            } else {
                Text(ConversationL10n.value("conversation.request_unavailable", "This request is unavailable."))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        // A question card is the actionable blocking surface.  Keep the
        // request identity in its value for diagnostics, but expose a stable
        // question landmark at the container level as well.  On iPadOS a
        // nested accessibility container can hide the identifier attached to
        // ConversationQuestionCard, leaving UI automation with only the
        // request wrapper.
        .accessibilityIdentifier(request.question == nil
            ? "ConversationBlockingRequest-\(request.id.rawValue)"
            : "ConversationBlockingQuestion")
        .accessibilityValue(request.question == nil ? request.id.rawValue : "\(request.id.rawValue)")
        .id(request.id.rawValue)
    }
}

struct ConversationQuestionCard: View {
    let request: ConversationRequest
    @Bindable var model: ConversationModel
    let isBlocking: Bool
    @State private var selectedOptionID: String?
    @State private var customAnswer = ""

    private var question: ConversationQuestion? { request.question }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            if let category = question?.category {
                Text(category.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if let index = question?.index, let total = question?.total, total > 1 {
                Text(String(format: ConversationL10n.value("conversation.question.progress", "%1$d of %2$d"), index + 1, total))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(question?.prompt ?? ConversationL10n.value("conversation.input_needed", "Input needed"))
                .font(.body.weight(.semibold))
            ForEach(question?.options ?? []) { option in
                Button {
                    selectedOptionID = option.id
                    model.answer(request: request, answers: [ConversationQuestionAnswer(index: question?.index ?? 0, optionID: option.id)])
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: selectedOptionID == option.id ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedOptionID == option.id ? .blue : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label).foregroundStyle(.primary)
                            if let detail = option.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ConversationQuestionOption-\(option.id)")
            }
            if question?.allowsCustomAnswer == true {
                if question?.isSecret == true {
                    SecureField(ConversationL10n.value("conversation.your_answer", "Your answer"), text: $customAnswer)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("ConversationQuestionCustomAnswer")
                } else {
                    TextField(ConversationL10n.value("conversation.your_answer", "Your answer"), text: $customAnswer, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("ConversationQuestionCustomAnswer")
                }
            }
            if question?.allowsCustomAnswer == true {
                HStack {
                    Button(ConversationL10n.value("conversation.send", "Send")) {
                        model.answer(request: request, value: customAnswer)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(customAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("ConversationQuestionSendButton")
                    Spacer()
                }
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(isBlocking ? "ConversationBlockingQuestion" : "ConversationAsyncQuestion")
        .id(request.id.rawValue)
    }
}

#endif
