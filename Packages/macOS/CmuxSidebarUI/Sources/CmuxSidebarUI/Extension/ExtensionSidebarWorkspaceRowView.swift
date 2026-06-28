public import CmuxSidebarProviderKit
public import Foundation
public import SwiftUI
import AppKit
import CmuxSidebar
import WebKit

/// A single extension-provider workspace row in the sidebar.
///
/// A pure presentation leaf: it holds no app-target state and reads no
/// `Workspace`/`TabManager`. It is handed an immutable
/// ``CmuxSidebarProviderRow`` plus an optional ``CmuxSidebarProviderWorkspace``
/// snapshot and two closures (`onSelect`, `onOpenWindow`), and renders the
/// title/subtitle/trailing text plus an optional inspector accessory popover.
public struct CmuxExtensionSidebarWorkspaceRowView: View, Equatable {
    let row: CmuxSidebarProviderRow
    let workspace: CmuxSidebarProviderWorkspace?
    let providerId: String
    let relativeNow: Date
    let isSelected: Bool
    let onSelect: (UUID) -> Void
    let onOpenWindow: (CmuxSidebarProviderWorkspace) -> Void
    @State private var showsInspector = false
    @State private var inspectorDraft: CmuxExtensionWorkspaceInspectorDraft?

    /// Creates an extension-provider workspace row.
    /// - Parameters:
    ///   - row: The immutable provider row snapshot (title/subtitle/accessory).
    ///   - workspace: The provider workspace snapshot backing the inspector, if any.
    ///   - providerId: The provider id the row belongs to.
    ///   - relativeNow: The reference date used to render relative timestamps.
    ///   - isSelected: Whether the row is the selected workspace.
    ///   - onSelect: Invoked with the row's workspace id when the row is tapped.
    ///   - onOpenWindow: Invoked with the workspace snapshot to open its window.
    public init(
        row: CmuxSidebarProviderRow,
        workspace: CmuxSidebarProviderWorkspace?,
        providerId: String,
        relativeNow: Date,
        isSelected: Bool,
        onSelect: @escaping (UUID) -> Void,
        onOpenWindow: @escaping (CmuxSidebarProviderWorkspace) -> Void
    ) {
        self.row = row
        self.workspace = workspace
        self.providerId = providerId
        self.relativeNow = relativeNow
        self.isSelected = isSelected
        self.onSelect = onSelect
        self.onOpenWindow = onOpenWindow
    }

    public nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row &&
            lhs.workspace == rhs.workspace &&
            lhs.providerId == rhs.providerId &&
            lhs.relativeNow == rhs.relativeNow &&
            lhs.isSelected == rhs.isSelected
    }

    private var isSuperCompact: Bool {
        false
    }

    private var isThin: Bool {
        false
    }

    public var body: some View {
        let primarySize: CGFloat = isSuperCompact ? 10.5 : 12.5
        let secondarySize: CGFloat = isSuperCompact ? 9 : 10
        HStack(spacing: isSuperCompact ? 5 : 7) {
            VStack(alignment: .leading, spacing: isSuperCompact ? 0 : 2) {
                Text(row.title)
                    .font(.system(size: primarySize, weight: .regular))
                    .foregroundColor(isSelected ? .primary : .primary.opacity(0.86))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if !isSuperCompact, let subtitle = rendered(row.subtitle) {
                    Text(subtitle)
                        .font(.system(size: secondarySize, weight: .regular))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !isSuperCompact, let trailing = rendered(row.trailingText) {
                Text(trailing)
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            if let accessory = row.accessory, let workspace {
                Button {
                    if inspectorDraft == nil {
                        inspectorDraft = CmuxExtensionWorkspaceInspectorDraft.initial(
                            workspace: workspace,
                            selectedTab: accessory.defaultTab
                        )
                    }
                    showsInspector = true
                } label: {
                    Image(systemName: accessory.systemImageName)
                        .font(.system(size: isSuperCompact ? 10 : 12, weight: .regular))
                        .frame(width: isSuperCompact ? 14 : 18, height: isSuperCompact ? 14 : 18)
                }
                .buttonStyle(.plain)
                .safeHelp(String(localized: "sidebar.extension.inspectWorkspace", defaultValue: "Workspace tools"))
                .popover(isPresented: $showsInspector, arrowEdge: .trailing) {
                    CmuxExtensionWorkspaceInspectorView(
                        workspace: workspace,
                        draft: Binding(
                            get: {
                                inspectorDraft ?? CmuxExtensionWorkspaceInspectorDraft.initial(
                                    workspace: workspace,
                                    selectedTab: accessory.defaultTab
                                )
                            },
                            set: { inspectorDraft = $0 }
                        ),
                        onOpenWindow: { onOpenWindow(workspace) }
                    )
                    .frame(width: 460, height: 340)
                }
            }
        }
        .padding(.leading, isSuperCompact ? 14 : 28)
        .padding(.trailing, 8)
        .padding(.vertical, isSuperCompact ? 2 : (isThin ? 5 : 7))
        .frame(minHeight: isSuperCompact ? 22 : 32)
        .background {
            if isSelected {
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect(row.workspaceId)
        }
    }

    private func rendered(_ text: CmuxSidebarProviderText?) -> String? {
        guard let text else { return nil }
        switch text {
        case .plain(let value):
            return value
        case .localized(let localized):
            return CmuxExtensionSidebarSelection().localizedText(localized)
        case .relativeDate(let date, _):
            return CmuxExtensionRelativeTimeFormatter.string(from: date, to: relativeNow)
        }
    }
}

struct CmuxExtensionWorkspaceInspectorDraft: Equatable {
    var selectedTab: CmuxSidebarProviderWorkspacePopoverTab
    var notes: String
    var address: String
    var committedAddress: String

    static func initial(
        workspace: CmuxSidebarProviderWorkspace,
        selectedTab: CmuxSidebarProviderWorkspacePopoverTab = .notes
    ) -> CmuxExtensionWorkspaceInspectorDraft {
        let initialAddress = workspace.pullRequestURLs.first ?? "https://github.com/"
        return CmuxExtensionWorkspaceInspectorDraft(
            selectedTab: selectedTab,
            notes: "",
            address: initialAddress,
            committedAddress: initialAddress
        )
    }
}

/// Formats a compact relative timestamp ("now", "5m", "3h", "2d", "1w") for
/// extension-sidebar rows, localized via the main bundle's `Localizable` table.
public enum CmuxExtensionRelativeTimeFormatter {
    /// Returns the localized compact relative-time string between `date` and `now`.
    public static func string(from date: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return String(localized: "relativeTime.now", defaultValue: "now") }
        let minutes = seconds / 60
        if minutes < 60 { return localizedCount("relativeTime.minutes", defaultValue: "%lldm", count: minutes) }
        let hours = minutes / 60
        if hours < 24 { return localizedCount("relativeTime.hours", defaultValue: "%lldh", count: hours) }
        let days = hours / 24
        if days < 7 { return localizedCount("relativeTime.days", defaultValue: "%lldd", count: days) }
        let weeks = days / 7
        return localizedCount("relativeTime.weeks", defaultValue: "%lldw", count: weeks)
    }

    private static func localizedCount(_ key: String, defaultValue: String, count: Int) -> String {
        let format = NSLocalizedString(
            key,
            tableName: "Localizable",
            bundle: .main,
            value: defaultValue,
            comment: ""
        )
        return String.localizedStringWithFormat(format, Int64(count))
    }
}

struct CmuxExtensionWorkspaceInspectorView: View {
    let workspace: CmuxSidebarProviderWorkspace
    let onOpenWindow: () -> Void
    @Binding private var draft: CmuxExtensionWorkspaceInspectorDraft

    init(
        workspace: CmuxSidebarProviderWorkspace,
        draft: Binding<CmuxExtensionWorkspaceInspectorDraft>,
        onOpenWindow: @escaping () -> Void
    ) {
        self.workspace = workspace
        self._draft = draft
        self.onOpenWindow = onOpenWindow
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $draft.selectedTab) {
                    Text(String(localized: "sidebar.extension.notesTab", defaultValue: "Notes")).tag(CmuxSidebarProviderWorkspacePopoverTab.notes)
                    Text(String(localized: "sidebar.extension.browserTab", defaultValue: "Browser")).tag(CmuxSidebarProviderWorkspacePopoverTab.browser)
                }
                .pickerStyle(.segmented)

                Button(action: onOpenWindow) {
                    Image(systemName: "macwindow")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .safeHelp(String(localized: "sidebar.extension.openWindow", defaultValue: "Open window"))
            }
            .padding(10)

            Divider()

            switch draft.selectedTab {
            case .notes:
                TextEditor(text: $draft.notes)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .accessibilityIdentifier("ExtensionSidebarNotesEditor")
            case .browser, .pullRequest:
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField(
                            String(localized: "sidebar.extension.browserAddress", defaultValue: "Search or enter URL"),
                            text: $draft.address
                        )
                        .textFieldStyle(.plain)
                        .onSubmit {
                            let normalized = CmuxExtensionWorkspaceInspectorBrowserView.normalizedAddress(draft.address)
                            draft.address = normalized
                            draft.committedAddress = normalized
                        }
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(Color(nsColor: .controlBackgroundColor))

                    CmuxExtensionWorkspaceInspectorBrowserView(address: draft.committedAddress)
                }
            }
        }
    }
}

struct CmuxExtensionWorkspaceInspectorWindowContentView: View {
    let workspace: CmuxSidebarProviderWorkspace
    let onOpenWindow: () -> Void
    @State private var draft: CmuxExtensionWorkspaceInspectorDraft

    init(
        workspace: CmuxSidebarProviderWorkspace,
        onOpenWindow: @escaping () -> Void
    ) {
        self.workspace = workspace
        self.onOpenWindow = onOpenWindow
        _draft = State(initialValue: CmuxExtensionWorkspaceInspectorDraft.initial(workspace: workspace))
    }

    var body: some View {
        CmuxExtensionWorkspaceInspectorView(
            workspace: workspace,
            draft: $draft,
            onOpenWindow: onOpenWindow
        )
    }
}

struct CmuxExtensionWorkspaceInspectorBrowserView: NSViewRepresentable {
    let address: String

    final class Coordinator {
        var loadedAddress: String?
    }

    static func normalizedAddress(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "https://github.com/" }
        if trimmed.contains("://") { return trimmed }
        if trimmed.contains(".") && !trimmed.contains(" ") { return "https://\(trimmed)" }
        let query = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        return "https://www.google.com/search?q=\(query)"
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let normalized = Self.normalizedAddress(address)
        guard context.coordinator.loadedAddress != normalized,
              let url = URL(string: normalized) else {
            return
        }
        context.coordinator.loadedAddress = normalized
        webView.load(URLRequest(url: url))
    }
}

/// Manages the per-workspace inspector windows opened from the extension
/// sidebar's workspace rows. Keyed by ``CmuxSidebarProviderWorkspace/id`` so a
/// second open focuses the existing window instead of spawning a duplicate.
@MainActor
public final class CmuxExtensionSidebarInspectorWindowController {
    private static var controllers: [UUID: NSWindowController] = [:]
    private static var closeObservers: [UUID: any NSObjectProtocol] = [:]

    /// Opens (or focuses) the inspector window for the given workspace snapshot.
    /// - Parameter workspace: The provider workspace snapshot to inspect.
    public static func show(workspace: CmuxSidebarProviderWorkspace) {
        if let controller = controllers[workspace.id] {
            controller.window?.title = workspace.title
            controller.window?.setContentSize(NSSize(width: 620, height: 440))
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            return
        }

        let view = CmuxExtensionWorkspaceInspectorWindowContentView(workspace: workspace) {
            show(workspace: workspace)
        }
        let hostingController = NSHostingController(rootView: view.frame(width: 620, height: 440))
        let window = NSWindow(contentViewController: hostingController)
        window.title = workspace.title
        window.identifier = NSUserInterfaceItemIdentifier("cmux.extensionSidebarInspector")
        window.setContentSize(NSSize(width: 620, height: 440))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        let controller = NSWindowController(window: window)
        controllers[workspace.id] = controller
        closeObservers[workspace.id] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            Task { @MainActor in
                controllers.removeValue(forKey: workspace.id)
                if let observer = closeObservers.removeValue(forKey: workspace.id) {
                    NotificationCenter.default.removeObserver(observer)
                }
            }
        }
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}
