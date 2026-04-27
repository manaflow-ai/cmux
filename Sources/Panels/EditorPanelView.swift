import SwiftUI
import WebKit

/// SwiftUI view that renders an EditorPanel's Monaco-based code viewer.
struct EditorPanelView: View {
    @ObservedObject var panel: EditorPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void

    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashAnimationGeneration: Int = 0
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if panel.hasWorkspaceFileExplorer {
                workspaceEditorView
            } else if panel.isFileUnavailable {
                fileUnavailableView
            } else {
                monacoEditorView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: FocusFlashPattern.ringCornerRadius)
                .stroke(Color.accentColor.opacity(focusFlashOpacity), lineWidth: 3)
                .shadow(color: Color.accentColor.opacity(focusFlashOpacity * 0.35), radius: 10)
                .padding(FocusFlashPattern.ringInset)
                .allowsHitTesting(false)
        }
        .onChange(of: panel.focusFlashToken) { _ in
            triggerFocusFlashAnimation()
        }
        .onChange(of: colorScheme) { newScheme in
            panel.setTheme(isDark: newScheme == .dark)
        }
    }

    // MARK: - Monaco WKWebView

    private var monacoEditorView: some View {
        VStack(spacing: 0) {
            filePathHeader
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 6)

            Divider()
                .padding(.horizontal, 12)

            EditorWebViewRepresentable(panel: panel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(backgroundColor)
        .contentShape(Rectangle())
        .onTapGesture {
            onRequestPanelFocus()
        }
    }

    private var filePathHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .foregroundColor(.secondary)
                .font(.system(size: 12))
            Text(panel.filePath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if panel.isDiffMode {
                Text(String(localized: "editor.diffMode", defaultValue: "Diff"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange))
            }
            Text(panel.monacoLanguage)
                .font(.system(size: 10))
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
        }
    }

    private var workspaceEditorView: some View {
        HStack(spacing: 0) {
            FileExplorerPanelView(
                store: panel.fileExplorerStore,
                state: panel.fileExplorerState,
                onOpenFile: { path in
                    panel.navigateToFile(path)
                }
            )
            .frame(width: 240)

            Divider()

            Group {
                if panel.isWorkspaceRootPlaceholder {
                    workspacePlaceholderView
                } else if panel.isFileUnavailable {
                    fileUnavailableView
                } else {
                    monacoEditorView
                }
            }
        }
        .background(backgroundColor)
    }

    private var workspacePlaceholderView: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text(String(localized: "editor.workspace.placeholder.title", defaultValue: "Code Viewer"))
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            Text(String(localized: "editor.workspace.placeholder.message", defaultValue: "Select a file from the file explorer to open it here."))
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                .multilineTextAlignment(.center)
            if let directory = panel.workspaceRootDirectory {
                Text(directory)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor)
    }

    private var fileUnavailableView: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text(String(localized: "editor.fileUnavailable", defaultValue: "File not found"))
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Text(panel.filePath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor)
    }

    // MARK: - Style

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(white: 0.12, alpha: 1.0))
            : Color(nsColor: NSColor(white: 0.98, alpha: 1.0))
    }

    // MARK: - Focus flash

    private func triggerFocusFlashAnimation() {
        let generation = focusFlashAnimationGeneration + 1
        focusFlashAnimationGeneration = generation

        let segments = FocusFlashPattern.segments
        var cumulativeDelay: TimeInterval = 0
        for segment in segments {
            cumulativeDelay = segment.delay
            let targetOpacity = segment.targetOpacity
            let duration = segment.duration
            DispatchQueue.main.asyncAfter(deadline: .now() + cumulativeDelay) {
                guard self.focusFlashAnimationGeneration == generation else { return }
                withAnimation(.easeInOut(duration: duration)) {
                    self.focusFlashOpacity = targetOpacity
                }
            }
        }
        let totalDuration = FocusFlashPattern.duration
        DispatchQueue.main.asyncAfter(deadline: .now() + totalDuration + 0.05) {
            guard self.focusFlashAnimationGeneration == generation else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                self.focusFlashOpacity = 0
            }
        }
    }
}

// MARK: - NSViewRepresentable wrapper for Monaco WKWebView

private struct EditorWebViewRepresentable: NSViewRepresentable {
    let panel: EditorPanel

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true

        let webView = panel.createWebView()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        panel.loadMonacoPage()

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Content updates are pushed via panel.pushContentToMonaco() triggered
        // by file watcher and Monaco ready callbacks, not by SwiftUI updates.
    }
}
