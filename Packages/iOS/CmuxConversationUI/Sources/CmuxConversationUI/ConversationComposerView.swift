#if os(iOS)
import CmuxConversation
import SwiftUI

struct ConversationComposerArea: View {
    @Bindable var model: ConversationModel
    @State private var showsCommandMenu = false
    @State private var showsEffortMenu = false
    @State private var pendingSteerOrQueue = false

    private var canSend: Bool {
        !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.connectionState == .connected
            && !model.isSubmitting
    }

    var body: some View {
        VStack(spacing: 8) {
            if let request = model.blockingRequest {
                ConversationRequestCard(request: request, model: model)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                HStack(alignment: .bottom, spacing: 9) {
                    Menu {
                        Button("Camera", systemImage: "camera") {}
                        Button("Photos", systemImage: "photo") {}
                        Button("Files", systemImage: "doc") {}
                        Divider()
                        Button("Plan mode", systemImage: "checklist") { model.updateDraft("/plan ") }
                        Button("Pursue goal", systemImage: "target") { model.updateDraft("/goal ") }
                    } label: {
                        Image(systemName: "plus")
                            .font(.headline.weight(.semibold))
                            .frame(width: 34, height: 34)
                            .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                    }
                    .accessibilityLabel("Add attachment or mode")
                    .accessibilityIdentifier("ConversationComposerPlus")

                    TextEditor(text: Binding(get: { model.draft }, set: { model.updateDraft($0) }))
                        .font(.body)
                        .frame(minHeight: 34, maxHeight: 118)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(alignment: .topLeading) {
                            if model.draft.isEmpty {
                                Text(model.isRunning ? "Follow up" : "Work on \(model.sessions.first(where: { $0.id == model.selectedSessionID })?.provider.displayName ?? "Cloud")")
                                    .font(.body)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 13)
                                    .allowsHitTesting(false)
                            }
                        }
                        .accessibilityIdentifier("ConversationComposerTextEditor")

                    if model.isRunning && model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button {
                            model.stop()
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.subheadline.weight(.bold))
                                .frame(width: 34, height: 34)
                                .background(.primary, in: Circle())
                                .foregroundStyle(.background)
                        }
                        .accessibilityLabel("Stop task")
                        .accessibilityIdentifier("ConversationStopButton")
                    } else {
                        Button {
                            model.submitDraft()
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.subheadline.weight(.bold))
                                .frame(width: 34, height: 34)
                                .background(canSend ? Color.accentColor : Color(uiColor: .tertiarySystemFill), in: Circle())
                                .foregroundStyle(canSend ? .white : .tertiary)
                        }
                        .disabled(!canSend)
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                                guard canSend, model.isRunning else { return }
                                pendingSteerOrQueue = true
                            }
                        )
                        .accessibilityLabel(model.isRunning ? "Send follow up" : "Send message")
                        .accessibilityIdentifier("ConversationSendButton")
                    }
                }
                .confirmationDialog("Send while working", isPresented: $pendingSteerOrQueue, titleVisibility: .visible) {
                    Button("Steer") { model.steer() }
                    Button("Queue") { model.queueTurn() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Choose whether this message should guide the current turn or wait in the queue.")
                }
            }
            HStack(spacing: 10) {
                Text(model.isRunning ? "Working" : "Ready")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Fast", action: {})
                    Button("Balanced", action: {})
                    Button("Thorough", action: {})
                } label: {
                    Label("Effort", systemImage: "gauge.with.dots.needle.67percent")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("ConversationEffortMenu")
            }
            .padding(.horizontal, 6)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.bar)
        .animation(.snappy, value: model.blockingRequest?.id)
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
                Label("Approval needed", systemImage: "hand.raised")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(approval.summary)
                    .font(.body.weight(.semibold))
                if let command = approval.command {
                    ConversationCodeBlock(text: command, label: "Command")
                }
                if approval.supportsAlwaysAllow {
                    Toggle("Always approve for this task", isOn: $allowSession)
                        .font(.subheadline)
                }
                HStack {
                    Button("Deny", role: .cancel) { model.resolveApproval(request, decision: .deny) }
                    Spacer()
                    Button("Approve") { model.resolveApproval(request, decision: allowSession ? .alwaysApprove : .approve) }
                        .buttonStyle(.borderedProminent)
                }
            } else if let question = request.question {
                ConversationQuestionCard(request: request, model: model, isBlocking: true)
            } else {
                Text("This request is unavailable.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityIdentifier("ConversationBlockingRequest-\(request.id.rawValue)")
    }
}

private struct ConversationQuestionCard: View {
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
                Text("\(index + 1) of \(total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(question?.prompt ?? "Input needed")
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
                TextField("Your answer", text: $customAnswer, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("ConversationQuestionCustomAnswer")
            }
            HStack {
                Button(customAnswer.isEmpty ? "Skip" : "Send") {
                    let text = customAnswer.isEmpty ? "Skipped" : customAnswer
                    model.answer(request: request, value: text)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedOptionID == nil && customAnswer.isEmpty && question?.allowsCustomAnswer == false)
                Spacer()
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityIdentifier(isBlocking ? "ConversationBlockingQuestion" : "ConversationAsyncQuestion")
    }
}

#endif
