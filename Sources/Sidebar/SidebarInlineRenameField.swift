import AppKit
import SwiftUI

/// Native single-line field used for inline workspace renaming in the sidebar.
struct SidebarInlineRenameField: View {
    @Binding var text: String
    let fontSize: CGFloat
    let textColor: Color
    let accessibilityLabel: String
    let placeholder: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    @FocusState private var isFocused: Bool
    @State private var hasResolved = false
    @State private var hasMovedCaretToStart = false

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundColor(textColor)
            .lineLimit(1)
            .focused($isFocused)
            .onAppear { focusAndSelectTitle() }
            .onSubmit { commitOnce() }
            .onExitCommand { handleExitCommand() }
            .onChange(of: isFocused) { wasFocused, isFocused in
                guard wasFocused, !isFocused else { return }
                commitOnce()
            }
            .accessibilityLabel(Text(accessibilityLabel))
    }

    private func commitOnce() {
        guard !hasResolved else { return }
        hasResolved = true
        onCommit(text)
    }

    private func cancelOnce() {
        guard !hasResolved else { return }
        hasResolved = true
        onCancel()
    }

    private func focusAndSelectTitle() {
        isFocused = true
        Task { @MainActor in
            await Task.yield()
            guard isFocused,
                  let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            editor.selectAll(nil)
        }
    }

    private func handleExitCommand() {
        guard hasMovedCaretToStart else {
            hasMovedCaretToStart = true
            (NSApp.keyWindow?.firstResponder as? NSTextView)?
                .setSelectedRange(NSRange(location: 0, length: 0))
            return
        }
        cancelOnce()
    }
}
