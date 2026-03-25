import AppKit
import SwiftUI
import WebKit

struct GitDiffPanelView: View {
    @ObservedObject var panel: GitDiffPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void

    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashAnimationGeneration: Int = 0
    @Environment(\.colorScheme) private var colorScheme

    private var stagedFiles: [GitChangedFile] {
        panel.changedFiles.filter(\.staged)
    }

    private var unstagedFiles: [GitChangedFile] {
        panel.changedFiles.filter { !$0.staged }
    }

    var body: some View {
        HSplitView {
            leftColumn
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 360)

            rightColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(backgroundColor)
        .overlay {
            RoundedRectangle(cornerRadius: FocusFlashPattern.ringCornerRadius)
                .stroke(cmuxAccentColor().opacity(focusFlashOpacity), lineWidth: 3)
                .shadow(color: cmuxAccentColor().opacity(focusFlashOpacity * 0.35), radius: 10)
                .padding(FocusFlashPattern.ringInset)
                .allowsHitTesting(false)
        }
        .onChange(of: panel.focusFlashToken) { _ in
            triggerFocusFlashAnimation()
        }
        .onChange(of: isVisibleInUI) { newValue in
            panel.setVisible(newValue)
        }
        .onAppear {
            panel.setVisible(isVisibleInUI)
        }
    }

    private var leftColumn: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            if !panel.isGitRepository {
                repositoryEmptyState(
                    icon: "arrow.triangle.branch",
                    title: String(localized: "gitDiff.notRepository.title", defaultValue: "Not a git repository"),
                    message: panel.workingDirectory
                )
            } else if panel.changedFiles.isEmpty {
                repositoryEmptyState(
                    icon: "checkmark.circle",
                    title: String(localized: "gitDiff.clean.title", defaultValue: "No changes"),
                    message: String(localized: "gitDiff.clean.message", defaultValue: "The working tree is clean.")
                )
            } else {
                List(selection: selectedFileBinding) {
                    if !stagedFiles.isEmpty {
                        Section(String(localized: "gitDiff.section.staged", defaultValue: "Staged")) {
                            ForEach(stagedFiles) { file in
                                fileRow(file)
                                    .tag(file)
                            }
                        }
                    }
                    if !unstagedFiles.isEmpty {
                        Section(String(localized: "gitDiff.section.unstaged", defaultValue: "Unstaged")) {
                            ForEach(unstagedFiles) { file in
                                fileRow(file)
                                    .tag(file)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
            footerView
        }
    }

    private var rightColumn: some View {
        Group {
            if !panel.isGitRepository {
                repositoryEmptyState(
                    icon: "arrow.triangle.branch",
                    title: String(localized: "gitDiff.notRepository.title", defaultValue: "Not a git repository"),
                    message: String(localized: "gitDiff.notRepository.message", defaultValue: "Open a workspace inside a repository to use Git Changes.")
                )
            } else if panel.changedFiles.isEmpty {
                repositoryEmptyState(
                    icon: "checkmark.circle",
                    title: String(localized: "gitDiff.clean.title", defaultValue: "No changes"),
                    message: String(localized: "gitDiff.clean.message", defaultValue: "The working tree is clean.")
                )
            } else if panel.selectedFile == nil {
                repositoryEmptyState(
                    icon: "doc.text.magnifyingglass",
                    title: String(localized: "gitDiff.selectFile.title", defaultValue: "Select a file to view diff"),
                    message: String(localized: "gitDiff.selectFile.message", defaultValue: "Choose a changed file from the list.")
                )
            } else {
                GitDiffWebContainerView(html: panel.diffHTML, onPointerDown: onRequestPanelFocus)
            }
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "gitDiff.header.title", defaultValue: "Git Changes"))
                    .font(.headline)
                Spacer()
                if let branchName = panel.branchName {
                    Label(branchName, systemImage: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Text(panel.workingDirectory)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var footerView: some View {
        HStack {
            Text(
                String(
                    localized: "gitDiff.footer.files",
                    defaultValue: "\(panel.changedFiles.count) files"
                )
            )
            .font(.caption)
            .foregroundColor(.secondary)

            Spacer()

            Button(String(localized: "gitDiff.refresh", defaultValue: "Refresh")) {
                onRequestPanelFocus()
                panel.refreshGitStatus()
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func fileRow(_ file: GitChangedFile) -> some View {
        Button(action: {
            onRequestPanelFocus()
            panel.selectFile(file)
        }) {
            HStack(spacing: 10) {
                Image(systemName: file.status.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(statusColor(for: file.status))
                    .frame(width: 14)
                Text(file.path)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func repositoryEmptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var selectedFileBinding: Binding<GitChangedFile?> {
        Binding(
            get: { panel.selectedFile },
            set: { newValue in
                onRequestPanelFocus()
                panel.selectFile(newValue)
            }
        )
    }

    private func statusColor(for status: GitFileStatus) -> Color {
        switch status {
        case .added, .copied:
            return .green
        case .modified, .renamed:
            return .orange
        case .deleted:
            return .red
        case .conflicted:
            return .yellow
        case .untracked:
            return .secondary
        }
    }

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(white: 0.12, alpha: 1.0))
            : Color(nsColor: NSColor(white: 0.98, alpha: 1.0))
    }

    private func triggerFocusFlashAnimation() {
        focusFlashAnimationGeneration += 1
        let generation = focusFlashAnimationGeneration
        focusFlashOpacity = FocusFlashPattern.values.first ?? 0

        for segment in FocusFlashPattern.segments {
            DispatchQueue.main.asyncAfter(deadline: .now() + segment.delay) {
                guard generation == focusFlashAnimationGeneration else { return }
                let animation: Animation = segment.curve == .easeIn
                    ? .easeIn(duration: segment.duration)
                    : .easeOut(duration: segment.duration)
                withAnimation(animation) {
                    focusFlashOpacity = segment.targetOpacity
                }
            }
        }
    }
}

private struct GitDiffWebContainerView: NSViewRepresentable {
    let html: String
    let onPointerDown: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPointerDown: onPointerDown)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.containerView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onPointerDown = onPointerDown
        context.coordinator.updateHTML(html)
    }

    final class Coordinator: NSObject {
        var onPointerDown: () -> Void
        private var webView: GitDiffWebView?
        let containerView: NSView
        private var currentHTML: String = ""

        init(onPointerDown: @escaping () -> Void) {
            self.onPointerDown = onPointerDown
            self.containerView = NSView(frame: .zero)
            super.init()
        }

        private func makeWebViewIfNeeded() -> GitDiffWebView {
            if let webView { return webView }
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

            let view = GitDiffWebView(frame: .zero, configuration: configuration)
            view.onPointerDown = { [weak self] in
                self?.onPointerDown()
            }
            view.translatesAutoresizingMaskIntoConstraints = false
            view.setValue(false, forKey: "drawsBackground")
            containerView.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                view.topAnchor.constraint(equalTo: containerView.topAnchor),
                view.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            ])
            webView = view
            return view
        }

        func updateHTML(_ html: String) {
            guard !html.isEmpty else { return }
            guard html != currentHTML else { return }
            currentHTML = html
            makeWebViewIfNeeded().loadHTMLString(html, baseURL: Bundle.main.resourceURL)
        }
    }
}

private final class GitDiffWebView: WKWebView {
    var onPointerDown: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onPointerDown?()
        super.mouseDown(with: event)
    }
}
