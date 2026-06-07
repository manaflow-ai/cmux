import AppKit
import SwiftUI

/// A persistent bottom status bar, in the spirit of VS Code / Cursor, that
/// surfaces the focused panel's Git branch (with a dirty indicator), its
/// working directory, and the active workspace + tab name.
///
/// The bar observes the selected ``Workspace`` directly. The workspace-level
/// `gitBranch` and `currentDirectory` already track the *focused* panel (their
/// values are promoted whenever focus moves between splits), so reading them
/// gives focused-panel scope while staying reactive to `@Published` changes.
///
/// This view sits in the main window chrome — outside any `LazyVStack`/`List`
/// row boundary — so observing the workspace here does not trip the
/// row-invalidation pitfalls that apply to list subtrees.
struct WorkspaceStatusBar: View {
    /// The workspace whose focused panel drives the bar's contents.
    @ObservedObject var workspace: Workspace
    /// Window appearance snapshot used to match the terminal chrome colors.
    let appearance: WindowAppearanceSnapshot

    var body: some View {
        HStack(spacing: 12) {
            branchItem
            directoryItem
            Spacer(minLength: 8)
            contextItem
        }
        .padding(.horizontal, 10)
        .frame(height: WindowChromeMetrics.statusBarHeight)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: appearance.terminalBackgroundColor))
        .overlay(alignment: .top) {
            WindowChromeBorder(orientation: .horizontal, ignoresSafeArea: false)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Items

    @ViewBuilder
    private var branchItem: some View {
        if let branch = trimmedBranch {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(secondaryColor)
                Text(branch)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(primaryColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isDirty {
                    Circle()
                        .fill(secondaryColor)
                        .frame(width: 5, height: 5)
                        .accessibilityLabel(Text(String(
                            localized: "statusBar.branch.dirty.accessibility",
                            defaultValue: "Uncommitted changes"
                        )))
                }
            }
            .help(String(localized: "statusBar.branch.help", defaultValue: "Current Git branch"))
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var directoryItem: some View {
        if let directory = focusedDirectory {
            Text(abbreviatedDirectory(directory))
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(secondaryColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(directory)
                .accessibilityLabel(Text(String(
                    localized: "statusBar.directory.accessibility",
                    defaultValue: "Working directory"
                )))
                .accessibilityValue(Text(directory))
        }
    }

    @ViewBuilder
    private var contextItem: some View {
        if !contextText.isEmpty {
            Text(contextText)
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(secondaryColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityLabel(Text(String(
                    localized: "statusBar.context.accessibility",
                    defaultValue: "Workspace and tab"
                )))
                .accessibilityValue(Text(contextText))
        }
    }

    // MARK: - Derived values (focused panel)

    /// The focused panel id, used to enrich the workspace-level values with
    /// per-panel directory and tab title.
    private var focusedPanelId: UUID? {
        workspace.focusedPanelId
    }

    /// The focused panel's branch name, trimmed; `nil` when not in a repo.
    private var trimmedBranch: String? {
        let branch = workspace.gitBranch?.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        return (branch?.isEmpty == false) ? branch : nil
    }

    /// Whether the focused panel's working tree has uncommitted changes.
    private var isDirty: Bool {
        workspace.gitBranch?.isDirty ?? false
    }

    /// The focused panel's working directory, preferring the per-panel value
    /// and falling back to the workspace's current directory.
    private var focusedDirectory: String? {
        if let panelId = focusedPanelId,
           let dir = workspace.panelDirectories[panelId]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !dir.isEmpty {
            return dir
        }
        let dir = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return dir.isEmpty ? nil : dir
    }

    /// The "workspace · tab" trailing context string. The tab title is omitted
    /// when it is empty or identical to the workspace title.
    private var contextText: String {
        let title = workspace.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let tab = focusedPanelId
            .flatMap { workspace.panelTitles[$0] }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if tab.isEmpty || tab == title {
            return title
        }
        if title.isEmpty {
            return tab
        }
        return "\(title) · \(tab)"
    }

    // MARK: - Formatting

    /// Replaces the home-directory prefix with `~` for a compact path.
    private func abbreviatedDirectory(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - Colors (matched to terminal chrome)

    private var isLightChrome: Bool {
        appearance.terminalBackgroundColor.isLightColor
    }

    private var primaryColor: Color {
        isLightChrome ? Color.black.opacity(0.78) : Color.white.opacity(0.82)
    }

    private var secondaryColor: Color {
        isLightChrome ? Color.black.opacity(0.55) : Color.white.opacity(0.6)
    }
}
