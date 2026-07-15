import CmuxBrowser
import SwiftUI

/// Cursor-style floating composer card for Design Mode.
///
/// Matches Cursor's design-mode composer: a flat dark card with the selected
/// element chips inline ahead of the change-description field, and a footer
/// with the copy shortcut hint and action. Always renders dark, like the
/// selection overlays it accompanies.
struct BrowserDesignModePopover: View {
    @Bindable var controller: BrowserDesignModeController
    @FocusState private var requestFieldFocused: Bool
    @State private var isCloseHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let selections = controller.snapshot?.selections, !selections.isEmpty {
                HStack(alignment: .center, spacing: 10) {
                    composerRow(selections)
                    copyButton
                }
                errorMessage
            } else {
                emptyState
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(width: 420)
        .background(cardBackground)
        .environment(\.colorScheme, .dark)
        .onExitCommand { controller.dismissComposer() }
        .onAppear { requestFieldFocused = controller.snapshot?.selections.isEmpty == false }
        .onChange(of: controller.snapshot?.selections.map(\.selector)) { _, selectors in
            requestFieldFocused = selectors?.isEmpty == false
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "browser.designMode.title", defaultValue: "Design Mode"))
    }

    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        return shape
            .fill(Color(red: 0.110, green: 0.110, blue: 0.118).opacity(0.98))
            .overlay(shape.strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
            .shadow(color: Color.black.opacity(0.35), radius: 14, y: 5)
    }

    private func composerRow(_ selections: [BrowserDesignModeSelection]) -> some View {
        BrowserDesignModeComposerRowLayout(spacing: 5, rowSpacing: 4, minimumFieldWidth: 150) {
            ForEach(Array(selections.enumerated()), id: \.offset) { index, selection in
                BrowserDesignModeSelectionChip(
                    selection: selection,
                    onRemove: {
                        Task { @MainActor in await controller.removeSelection(at: index) }
                    }
                )
            }
            requestField
        }
    }

    private var requestField: some View {
        TextField(
            String(
                localized: "browser.designMode.composer.describeChange",
                defaultValue: "Describe the change"
            ),
            text: $controller.requestedChange,
            axis: .vertical
        )
        .textFieldStyle(.plain)
        .lineLimit(1...5)
        .cmuxFont(size: 13.5)
        .foregroundStyle(.white.opacity(0.96))
        .tint(Color(red: 0.35, green: 0.62, blue: 1.0))
        .focused($requestFieldFocused)
        .onSubmit {
            Task { @MainActor in await controller.copySelection() }
        }
        .padding(.vertical, 5)
        .accessibilityLabel(
            String(
                localized: "browser.designMode.composer.describeChange",
                defaultValue: "Describe the change"
            )
        )
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

    /// Circular trailing action, mirroring the cmux agent composer's send
    /// button and Cursor's compact pill affordance. Shows a checkmark right
    /// after a successful copy.
    private var copyButton: some View {
        Button {
            Task { @MainActor in await controller.copySelection() }
        } label: {
            Image(systemName: controller.didCopy ? "checkmark" : "doc.on.clipboard.fill")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(
                        controller.canCopy || controller.didCopy
                            ? Color(red: 0.25, green: 0.47, blue: 0.96)
                            : Color.white.opacity(0.12)
                    )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!controller.canCopy)
        .safeHelp(
            "\(String(localized: "browser.designMode.copy", defaultValue: "Copy")) (\(String(localized: "browser.designMode.copy.shortcut", defaultValue: "⌘↩")))"
        )
        .accessibilityLabel(String(localized: "browser.designMode.copy", defaultValue: "Copy"))
        .accessibilityIdentifier("BrowserDesignModeCopyButton")
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
                    .foregroundStyle(.white.opacity(0.55))
                }
            }
            .cmuxFont(size: 11)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            closeButton
        }
    }

    private var closeButton: some View {
        Button {
            controller.dismissComposer()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(isCloseHovered ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.45)))
                .frame(width: 18, height: 18)
                .background(Circle().fill(isCloseHovered ? Color.white.opacity(0.12) : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isCloseHovered = $0 }
        .safeHelp(String(localized: "common.close", defaultValue: "Close"))
        .accessibilityLabel(String(localized: "common.close", defaultValue: "Close"))
    }
}
