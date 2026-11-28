import Bonsplit
import SwiftUI

/// Transcript, prompt, and pane controls for the selected Herd lane.
struct HerdPanelDetailView: View {
    @Bindable var model: HerdPanelModel
    let lane: HerdPanelSnapshot.Lane

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            composer
        }
        .accessibilityIdentifier("HerdPanelDetail")
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(lane.agentKey.map(displayAgentName) ?? lane.title)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(lane.workspaceTitle)  ·  \(lane.directory ?? lane.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                model.refreshTranscript()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(String(localized: "filePreview.refresh", defaultValue: "Refresh"))

            Menu {
                Button(String(localized: "command.terminalSplitRight.title", defaultValue: "Split Right")) {
                    model.splitSelectedLane(orientation: .horizontal)
                }
                Button(String(localized: "command.terminalSplitDown.title", defaultValue: "Split Down")) {
                    model.splitSelectedLane(orientation: .vertical)
                }
                Divider()
                Button(String(localized: "herd.action.interrupt", defaultValue: "Interrupt")) {
                    model.interruptSelectedLane(hard: false)
                }
                Button(String(localized: "herd.action.hardInterrupt", defaultValue: "Hard Interrupt")) {
                    model.interruptSelectedLane(hard: true)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)

            Button {
                model.focusSelectedLane()
            } label: {
                Label(String(localized: "herd.action.focus", defaultValue: "Focus"), systemImage: "scope")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
    }

    private var transcript: some View {
        ScrollView {
            if model.transcript.isEmpty {
                ContentUnavailableView {
                    Label(
                        String(localized: "herd.transcript.empty.title", defaultValue: "No terminal output"),
                        systemImage: "text.alignleft"
                    )
                } description: {
                    Text(String(localized: "herd.transcript.empty.description", defaultValue: "Refresh after the terminal produces output."))
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                Text(model.transcript)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.22))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $model.prompt)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 54, maxHeight: 110)
                .padding(6)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if model.prompt.isEmpty {
                        Text(String(localized: "herd.prompt.placeholder", defaultValue: "Send a prompt to this lane"))
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }

            HStack {
                feedbackLabel
                Spacer()
                Button {
                    model.sendPrompt()
                } label: {
                    Label(String(localized: "terminal.notification.action.replySend", defaultValue: "Send"), systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var feedbackLabel: some View {
        switch model.feedback {
        case .promptSent:
            Label(String(localized: "herd.feedback.sent", defaultValue: "Prompt sent"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .promptPastedButNotSubmitted:
            Label(String(localized: "herd.feedback.notSubmitted", defaultValue: "Prompt pasted. Press Return in the terminal."), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        case .terminalUnavailable:
            Label(String(localized: "herd.feedback.unavailable", defaultValue: "Terminal unavailable"), systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        case nil:
            EmptyView()
        }
    }

    private func displayAgentName(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }
}
