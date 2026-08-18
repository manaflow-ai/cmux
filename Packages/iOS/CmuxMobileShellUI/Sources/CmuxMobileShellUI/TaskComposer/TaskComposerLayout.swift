#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI
import UIKit

/// A full-screen prompt canvas with compact task controls above the keyboard.
struct TaskComposerLayout: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Binding var prompt: String
    let genericPromptPlaceholder: String
    let workspaceName: String
    let directory: String
    let isDisabled: Bool
    let locksDismissal: Bool
    let templates: [MobileTaskTemplate]
    let selectedTemplateID: MobileTaskTemplate.ID?
    let models: [MobileTaskAgentModel]
    let selectedModelID: String?
    let efforts: [MobileTaskAgentEffort]
    let selectedEffortID: String?
    let modelErrorText: String?
    let effortErrorText: String?
    let agentErrorText: String?
    let isModelLoading: Bool
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
    let selectModel: (MobileTaskAgentModel?) -> Void
    let selectEffort: (MobileTaskAgentEffort?) -> Void
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
        TaskComposerKeyboardDock(
            canvas: promptCanvas,
            accessory: accessoryBar
        )
        // Keep one full-height controller mounted across rotations and Split
        // View resizing. UIKit's keyboard guide owns the dock position without
        // recreating the prompt editor or its focus state.
        .ignoresSafeArea(.container, edges: .bottom)
        .ignoresSafeArea(.keyboard, edges: .bottom)
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
                leadingUtilityButtons
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)

                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        agentPill
                            .fixedSize(horizontal: true, vertical: false)

                        if isModelLoading {
                            modelLoadingPill
                                .fixedSize(horizontal: true, vertical: false)
                                .transition(modelLoadingTransition)
                        } else if !models.isEmpty || !efforts.isEmpty || modelErrorText != nil {
                            if models.isEmpty, modelErrorText != nil {
                                modelErrorPill
                                    .fixedSize(horizontal: true, vertical: false)
                            } else {
                                modelPill
                                    .fixedSize(horizontal: true, vertical: false)
                            }

                            if !efforts.isEmpty || effortErrorText != nil {
                                effortPill
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                // The shared picker strip owns overflow. Pills keep their
                // readable intrinsic widths while the fixed edge controls
                // claim their space outside this clipped viewport.
                .frame(minWidth: 0, maxWidth: .infinity)
                .layoutPriority(0)
                .clipped()
                .accessibilityIdentifier("MobileTaskComposerPillScroller")

                submitButton
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileTaskComposerAccessoryBar")
    }

    private var leadingUtilityButtons: some View {
        // Adjacent 44pt hit regions leave a deliberate 6pt gap between the
        // 38pt circles, grouping these related utilities without overlap.
        HStack(spacing: 0) {
            optionsButton

            if showsAttachmentButton {
                TaskComposerAttachmentPickerMenu(
                    style: .circularPlus,
                    isDisabled: isDisabled,
                    choosePhotos: chooseAttachmentPhotos,
                    chooseFiles: chooseAttachmentFiles
                )
            }
        }
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

                    Text(agentErrorText ?? agentPillTitle(for: selectedTemplate))
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
            .foregroundStyle(agentErrorText == nil ? Color.primary : Color.red)
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .background(Color.primary.opacity(0.07), in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .tint(Color.primary)
        .disabled(isDisabled)
        .accessibilityLabel(L10n.string("mobile.taskComposer.agent", defaultValue: "Agent"))
        .accessibilityValue(agentErrorText ?? selectedTemplate?.name ?? "")
        .accessibilityHint(TaskComposerSheet.templateAccessibilityHint)
        .accessibilityIdentifier("MobileTaskComposerAgentPill")
        // Recreate the whole Menu when the title changes: the UIKit menu
        // button otherwise animates its frame to the new width on iOS 26 and
        // clips the label against the stale bounds until it settles.
        .id((selectedTemplate.map(agentPillTitle(for:)) ?? "") + (agentErrorText ?? ""))
    }

    private var modelPill: some View {
        HStack(spacing: 7) {
            Image(systemName: "cpu")
                .font(.caption.weight(.semibold))
                .accessibilityHidden(true)

            Text(modelErrorText ?? selectedModelName)
                .lineLimit(1)

            Image(systemName: "chevron.down")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(modelErrorText == nil ? Color.primary : Color.red)
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        .background(Color.primary.opacity(0.07), in: Capsule())
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityHidden(true)
        .overlay {
            TaskComposerModelMenuContent(
                models: models,
                selectedModelID: selectedModelID,
                selectedModelName: selectedModelName,
                isEnabled: !isDisabled,
                selectModel: selectModel
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // See agentPill: identity-swap the pill so the new title cannot be
        // clipped by the old frame mid-animation.
        .id((modelErrorText ?? "") + selectedModelName)
    }

    private var modelErrorPill: some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle")
                .font(.caption.weight(.semibold))
                .accessibilityHidden(true)

            Text(modelErrorText ?? L10n.string(
                "mobile.taskComposer.model.error.queryFailed",
                defaultValue: "Couldn’t load models"
            ))
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(Color.red)
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        .background(Color.red.opacity(0.12), in: Capsule())
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(modelErrorText ?? L10n.string(
            "mobile.taskComposer.model.error.queryFailed",
            defaultValue: "Couldn’t load models"
        ))
        .accessibilityIdentifier("MobileTaskComposerModelErrorPill")
    }

    private var modelLoadingPill: some View {
        HStack(spacing: 7) {
            Image(systemName: "cpu")
                .font(.caption.weight(.semibold))
                .accessibilityHidden(true)

            Text(L10n.string(
                "mobile.taskComposer.model.loading",
                defaultValue: "Loading models"
            ))
                .lineLimit(1)

            ProgressView()
                .controlSize(.mini)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        .background(Color.primary.opacity(0.07), in: Capsule())
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string(
            "mobile.taskComposer.model.loading",
            defaultValue: "Loading models"
        ))
        .accessibilityIdentifier("MobileTaskComposerModelLoadingPill")
    }

    private var modelLoadingTransition: AnyTransition {
        guard !accessibilityReduceMotion else { return .identity }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.96)),
            removal: .opacity
                .combined(with: .scale(scale: 0.98))
        )
    }

    private var effortPill: some View {
        HStack(spacing: 7) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.caption.weight(.semibold))
                .accessibilityHidden(true)

            Text(effortErrorText ?? selectedEffortName)
                .lineLimit(1)

            Image(systemName: "chevron.down")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(
            effortErrorText != nil
                ? Color.red
                : (efforts.isEmpty ? Color.secondary : Color.primary)
        )
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        .background(Color.primary.opacity(0.07), in: Capsule())
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityHidden(true)
        .overlay {
            TaskComposerEffortMenuContent(
                efforts: efforts,
                selectedEffortID: selectedEffortID,
                selectedEffortName: selectedEffortName,
                isEnabled: !isDisabled && !efforts.isEmpty,
                selectEffort: selectEffort
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .id((effortErrorText ?? "") + selectedEffortName)
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

    private var selectedModelName: String {
        models.displayName(forSelected: selectedModelID)
    }

    private var selectedEffortName: String {
        guard let selectedEffortID,
              let effort = efforts.first(where: { $0.id == selectedEffortID }) else {
            return L10n.string(
                "mobile.taskComposer.effort",
                defaultValue: "Effort"
            )
        }
        return effort.displayName
    }

    private var navigationTitle: String {
        let trimmedWorkspaceName = workspaceName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !trimmedWorkspaceName.isEmpty {
            return trimmedWorkspaceName
        }
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
        TaskComposerAgentMenuValue(
            templates: templates,
            selectedTemplateID: selectedTemplateID,
            isDisabled: isDisabled
        )
    }

    private var agentMenuActions: TaskComposerAgentMenuActions {
        TaskComposerAgentMenuActions(
            selectTemplate: selectTemplate,
            editTemplates: editTemplates
        )
    }
}
#endif
