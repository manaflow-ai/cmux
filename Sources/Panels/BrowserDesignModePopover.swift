import CmuxBrowser
import SwiftUI

/// Cursor-style floating composer card for Design Mode.
///
/// Shows the selected element chips, a change-description field, and the
/// copy action. Visual language mirrors the cmux agent composer
/// (`TextBoxInput`): material card, continuous 15pt corners, hairline
/// stroke, compact pill chips.
struct BrowserDesignModePopover: View {
    @Bindable var controller: BrowserDesignModeController
    @FocusState private var requestFieldFocused: Bool
    @State private var isCloseHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let selections = controller.snapshot?.selections, !selections.isEmpty {
                selectionHeader(selections)
                requestEditor
                errorMessage
                footer
            } else {
                emptyState
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(width: 400)
        .background(cardBackground)
        .onExitCommand { controller.dismissComposer() }
        .onAppear { requestFieldFocused = controller.snapshot?.selections.isEmpty == false }
        .onChange(of: controller.snapshot?.selections.map(\.selector)) { _, selectors in
            requestFieldFocused = selectors?.isEmpty == false
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "browser.designMode.title", defaultValue: "Design Mode"))
    }

    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        return shape
            .fill(.regularMaterial)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
            .shadow(color: Color.black.opacity(0.18), radius: 12, y: 4)
    }

    private func selectionHeader(_ selections: [BrowserDesignModeSelection]) -> some View {
        HStack(alignment: .top, spacing: 6) {
            BrowserDesignModeChipFlowLayout(spacing: 4) {
                ForEach(Array(selections.enumerated()), id: \.offset) { index, selection in
                    BrowserDesignModeSelectionChip(
                        selection: selection,
                        onRemove: {
                            Task { @MainActor in await controller.removeSelection(at: index) }
                        }
                    )
                }
            }
            Spacer(minLength: 0)
            closeButton
        }
    }

    private var closeButton: some View {
        Button {
            controller.dismissComposer()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(isCloseHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 18, height: 18)
                .background(Circle().fill(isCloseHovered ? Color.primary.opacity(0.12) : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isCloseHovered = $0 }
        .safeHelp(String(localized: "common.close", defaultValue: "Close"))
        .accessibilityLabel(String(localized: "common.close", defaultValue: "Close"))
    }

    private var requestEditor: some View {
        ZStack(alignment: .topLeading) {
            if controller.requestedChange.isEmpty {
                Text(
                    String(
                        localized: "browser.designMode.composer.describeChange",
                        defaultValue: "Describe the change"
                    )
                )
                .cmuxFont(size: 13)
                .foregroundStyle(.tertiary)
                .padding(.leading, 5)
                .padding(.top, 1)
                .allowsHitTesting(false)
            }
            TextEditor(text: $controller.requestedChange)
                .cmuxFont(size: 13)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .focused($requestFieldFocused)
                .frame(minHeight: 40, maxHeight: 110)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(
                    String(
                        localized: "browser.designMode.composer.describeChange",
                        defaultValue: "Describe the change"
                    )
                )
        }
    }

    @ViewBuilder
    private var errorMessage: some View {
        if let message = controller.errorMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .cmuxFont(size: 11)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if controller.didCopy {
                Label(
                    String(localized: "browser.designMode.copy.copied", defaultValue: "Copied"),
                    systemImage: "checkmark"
                )
                .cmuxFont(size: 11, weight: .medium)
                .foregroundStyle(.green)
                .transition(.opacity)
            }
            Spacer(minLength: 0)
            Text(String(localized: "browser.designMode.copy.shortcut", defaultValue: "⌘↩"))
                .cmuxFont(size: 11)
                .foregroundStyle(.tertiary)
            Button {
                Task { @MainActor in await controller.copySelection() }
            } label: {
                Text(
                    controller.isCopying
                        ? String(localized: "browser.designMode.copy.copying", defaultValue: "Copying…")
                        : String(localized: "browser.designMode.copy", defaultValue: "Copy")
                )
                .cmuxFont(size: 12, weight: .semibold)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!controller.canCopy)
            .accessibilityIdentifier("BrowserDesignModeCopyButton")
        }
    }

    private var emptyState: some View {
        HStack(alignment: .top, spacing: 6) {
            Group {
                if let message = controller.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else {
                    Text(
                        String(
                            localized: "browser.designMode.composer.pickElements",
                            defaultValue: "Select one or more elements on the page."
                        )
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .cmuxFont(size: 11)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            closeButton
        }
    }
}
