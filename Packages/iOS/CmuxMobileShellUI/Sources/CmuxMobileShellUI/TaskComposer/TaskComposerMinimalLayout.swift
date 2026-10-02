#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI
import UIKit

/// A full-screen prompt canvas with compact task controls above the keyboard.
struct TaskComposerMinimalLayout: View {
    @Binding var prompt: String
    let genericPromptPlaceholder: String
    let directory: String
    let isDisabled: Bool
    let locksDismissal: Bool
    let templates: [MobileTaskTemplate]
    let selectedTemplateID: MobileTaskTemplate.ID?
    let modelPickerVariant: TaskComposerModelPickerVariant
    let models: [MobileTaskAgentModel]
    let selectedModelID: String?
    let isSubmitting: Bool
    let isSubmitEnabled: Bool
    let failureTitle: String
    let failureText: String?
    let completedOperationRecovery: TaskComposerCompletedOperationRecovery?
    let attachments: [TaskComposerAttachment]
    let showsAttachmentButton: Bool
    /// Deferred builder: constructing the options sheet walks workspaces for
    /// directory candidates, so it must not run on every keystroke's body
    /// rebuild, only when Task Options is actually presented.
    let optionsSheet: () -> TaskComposerOptionsSheet
    let endEditing: () -> Void
    let selectTemplate: (MobileTaskTemplate.ID) -> Void
    let selectTemplateAndModel: (MobileTaskTemplate.ID, String?) -> Void
    let selectModel: (String?) -> Void
    let editTemplates: () -> Void
    let cancel: () -> Void
    let submit: () -> Void
    let refreshCompletedOperation: () -> Void
    let requestStartAgain: () -> Void
    let chooseAttachmentPhotos: () -> Void
    let chooseAttachmentFiles: () -> Void
    let removeAttachment: (UUID) -> Void

    @State private var isPromptFocused = false
    @State private var isOptionsPresented = false

    var body: some View {
        promptCanvas
            .safeAreaInset(edge: .bottom, spacing: 0) {
                accessoryBar
            }
            .navigationTitle(navigationTitle)
            .mobileInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: cancel) {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(locksDismissal)
                    .accessibilityLabel(L10n.string(
                        "mobile.common.cancel",
                        defaultValue: "Cancel"
                    ))
                    .accessibilityIdentifier("MobileTaskComposerCancelButton")
                }
            }
            .sheet(isPresented: $isOptionsPresented) {
                optionsSheet()
            }
    }

    private var promptCanvas: some View {
        ZStack(alignment: .topLeading) {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            if prompt.isEmpty {
                Text(promptPlaceholder)
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 27)
                    .padding(.horizontal, 25)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            TaskComposerPromptEditor(
                text: $prompt,
                isFocused: $isPromptFocused,
                isDisabled: isDisabled,
                accessibilityLabel: L10n.string(
                    "mobile.taskComposer.prompt",
                    defaultValue: "Prompt"
                ),
                accessibilityHint: promptPlaceholder
            )
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .taskComposerEditingCompletion(
                    isFocused: isPromptFocused,
                    endEditing: endEditing
                )
        }
    }

    private var accessoryBar: some View {
        VStack(spacing: 10) {
            if failureText != nil || completedOperationRecovery != nil {
                TaskComposerFailureRecoveryContent(
                    isSubmitting: isSubmitting,
                    failureTitle: failureTitle,
                    failureText: failureText,
                    completedOperationRecovery: completedOperationRecovery,
                    refreshCompletedOperation: refreshCompletedOperation,
                    requestStartAgain: requestStartAgain
                )
                .padding(.horizontal, 16)
            }

            if !attachments.isEmpty {
                TaskComposerAttachmentStrip(
                    attachments: attachments,
                    isDisabled: isDisabled,
                    remove: removeAttachment
                )
                .padding(.horizontal, 16)
            }

            HStack(spacing: 10) {
                if showsAttachmentButton {
                    TaskComposerAttachmentPickerMenu(
                        style: .circularPlus,
                        isDisabled: isDisabled,
                        choosePhotos: chooseAttachmentPhotos,
                        chooseFiles: chooseAttachmentFiles
                    )
                }

                optionsButton

                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        agentPill

                        if !models.isEmpty, showsStandaloneModelPill {
                            modelPill
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("MobileTaskComposerPillScroller")

                submitButton
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
        // Blend into the canvas like the reference composer; the keyboard
        // provides the visual boundary below.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .background(Color(uiColor: .systemBackground))
    }

    private var optionsButton: some View {
        Button {
            isOptionsPresented = true
        } label: {
            // Adjustments glyph, not "+": the button configures the task
            // (name, Mac, directory), it does not add anything.
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(Color.primary.opacity(0.07), in: Circle())
                // Keep the compact 38pt visual while honoring the composer's
                // 44pt activation-target contract.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(L10n.string(
            "mobile.taskComposer.options.title",
            defaultValue: "Task Options"
        ))
        .accessibilityIdentifier("MobileTaskComposerOptionsButton")
    }

    private var agentPill: some View {
        Menu {
            TaskComposerAgentMenuContent(
                value: agentMenuValue,
                actions: agentMenuActions
            )
        } label: {
            HStack(spacing: 7) {
                if let selectedTemplate {
                    TaskTemplateIcon(value: selectedTemplate.icon, size: 16)
                        .frame(width: 18, height: 18)

                    Text(agentPillTitle(for: selectedTemplate))
                        .lineLimit(1)
                } else {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .font(.system(size: 14, weight: .semibold))
                        .accessibilityHidden(true)

                    Text(L10n.string(
                        "mobile.taskComposer.agent",
                        defaultValue: "Agent"
                    ))
                }

                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            // A longer title must widen the capsule immediately; animating the
            // frame clips the label against the stale width until it settles.
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .background(Color.primary.opacity(0.07), in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .tint(Color.primary)
        .disabled(isDisabled)
        .accessibilityLabel(L10n.string("mobile.taskComposer.agent", defaultValue: "Agent"))
        .accessibilityValue(selectedTemplate?.name ?? "")
        .accessibilityHint(TaskComposerSheet.templateAccessibilityHint)
        .accessibilityIdentifier("MobileTaskComposerAgentPill")
        // Recreate the whole Menu when the title changes: the UIKit menu
        // button otherwise animates its frame to the new width on iOS 26 and
        // clips the label against the stale bounds until it settles.
        .id(selectedTemplate.map(agentPillTitle(for:)))
    }

    private var modelPill: some View {
        Menu {
            TaskComposerModelMenuContent(
                models: models,
                selectedModelID: selectedModelID,
                selectModel: selectModel
            )
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "cpu")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)

                Text(selectedModelName)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            // See agentPill: adopt the new title's width immediately instead
            // of animating (and clipping) into it.
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .background(Color.primary.opacity(0.07), in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .tint(Color.primary)
        .disabled(isDisabled)
        .taskComposerModelAccessibility(valueName: selectedModelName)
        .accessibilityIdentifier("MobileTaskComposerModelPill")
        // See agentPill: identity-swap the Menu so the new title cannot be
        // clipped by the old button frame mid-animation.
        .id(selectedModelName)
    }

    private var submitButton: some View {
        Button(action: submit) {
            Group {
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(isSubmitEnabled ? .white : .secondary)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                }
            }
            .frame(width: 38, height: 38)
            .foregroundStyle(isSubmitEnabled ? Color.white : Color.secondary)
            .background(
                isSubmitEnabled ? Color.accentColor : Color.primary.opacity(0.12),
                in: Circle()
            )
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting || !isSubmitEnabled)
        .accessibilityLabel(L10n.string(
            "mobile.taskComposer.submit",
            defaultValue: "Start Task"
        ))
        .accessibilityHint(TaskComposerSheet.createAccessibilityHint)
        .accessibilityIdentifier("MobileTaskComposerSubmitButton")
    }

    private var selectedTemplate: MobileTaskTemplate? {
        selectedTemplateID.flatMap { id in templates.first { $0.id == id } }
    }

    private func agentPillTitle(for template: MobileTaskTemplate) -> String {
        template.name
    }

    /// The composer layout has ONE canonical model treatment regardless of the
    /// classic-layout lab variant: a dedicated pill beside the agent pill,
    /// mirroring the reference composer. The agent menu stays plain (see
    /// `agentMenuValue`), so the pill is the single model entry point.
    private var showsStandaloneModelPill: Bool {
        modelPickerVariant.renderedVariant != .off
    }

    private var selectedModelName: String {
        models.displayName(forSelected: selectedModelID)
    }

    private var navigationTitle: String {
        guard !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return L10n.string("mobile.taskComposer.title", defaultValue: "New Task")
        }
        return TaskComposerDirectoryDisplayPath(path: directory).name
    }

    private var promptPlaceholder: String {
        guard !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return genericPromptPlaceholder
        }
        return String(
            format: L10n.string(
                "mobile.taskComposer.composer.promptPlaceholderFormat",
                defaultValue: "Describe a coding task in %@"
            ),
            TaskComposerDirectoryDisplayPath(path: directory).name
        )
    }

    private var agentMenuValue: TaskComposerAgentMenuValue {
        // Force the plain (non-combined) agent menu: the standalone model
        // pill is this layout's single model entry point, so the menu must
        // not duplicate model submenus even when the classic-layout lab
        // variant is `combined`.
        TaskComposerAgentMenuValue(
            templates: templates,
            selectedTemplateID: selectedTemplateID,
            modelPickerVariant: modelPickerVariant.renderedVariant == .combined
                ? .separateRow
                : modelPickerVariant,
            models: models,
            selectedModelID: selectedModelID,
            isDisabled: isDisabled
        )
    }

    private var agentMenuActions: TaskComposerAgentMenuActions {
        TaskComposerAgentMenuActions(
            selectTemplate: selectTemplate,
            selectTemplateAndModel: selectTemplateAndModel,
            editTemplates: editTemplates
        )
    }
}
#endif
