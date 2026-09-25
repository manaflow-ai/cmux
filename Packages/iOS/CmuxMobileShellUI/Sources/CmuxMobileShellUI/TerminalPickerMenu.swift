import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Snapshot-isolated native menu for switching the active workspace surface.
struct TerminalPickerMenu: View, Equatable {
    let value: TerminalPickerMenuValue
    let actions: TerminalPickerMenuActions
    let terminalTheme: TerminalTheme
    #if DEBUG
    private let diagnostics = TerminalPickerMenuDiagnostics()
    #endif

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.value == rhs.value && lhs.terminalTheme == rhs.terminalTheme
    }

    var body: some View {
        Menu {
            instrumentedMenuContent
        } label: {
            Label(
                value.selectedName ?? L10n.string("mobile.terminal.select", defaultValue: "Terminal"),
                systemImage: "rectangle.stack"
            )
            .labelStyle(.iconOnly)
        }
        .foregroundStyle(terminalTheme.terminalChromeForegroundColor)
        .accessibilityLabel(L10n.string("mobile.terminal.picker.title", defaultValue: "Terminals"))
        .accessibilityIdentifier("MobileTerminalDropdown")
        .accessibilityValue(value.selectedName ?? "")
    }

    @ViewBuilder
    private var instrumentedMenuContent: some View {
        #if DEBUG
        let _ = diagnostics.recordContentBuilderEvaluation(rowCount: value.rows.count)
        #endif
        menuContent
    }

    @ViewBuilder
    private var menuContent: some View {
        if let layout = value.sshTabLayout {
            groupedTerminalSections(layout)
        } else {
            Section(L10n.string("mobile.terminal.picker.title", defaultValue: "Terminals")) {
                ForEach(value.terminalRows) { terminal in
                    // Toggle rows get the native leading checkmark while the kind
                    // glyph stays on the trailing edge, matching system pickers.
                    Toggle(isOn: Binding(
                        get: { terminal.id == value.checkedRowID },
                        set: { _ in
                            if let id = terminal.terminalID { actions.selectTerminal(id) }
                        }
                    )) {
                        Label(terminal.name, systemImage: "terminal")
                    }
                    .accessibilityIdentifier("MobileTerminalMenuItem-\(terminal.terminalID?.rawValue ?? "")")
                }
            }
        }

        if !value.macSurfaceRows.isEmpty {
            Section(L10n.string("mobile.surface.section", defaultValue: "Mac Surfaces")) {
                ForEach(value.macSurfaceRows) { surface in
                    Toggle(isOn: Binding(
                        get: { surface.id == value.checkedRowID },
                        set: { _ in
                            if let id = surface.macSurfaceID { actions.selectMacSurface(id) }
                        }
                    )) {
                        Label(surface.name, systemImage: surface.surfaceKind.systemImage)
                    }
                    .accessibilityIdentifier("MobileMacSurfaceMenuItem-\(surface.macSurfaceID?.rawValue ?? "")")
                }
            }
        }

        if value.supportsSimulatorStream, !value.simulatorStreamRows.isEmpty {
            Section(L10n.string("mobile.simulatorStream.menuTitle", defaultValue: "Mac Simulators")) {
                ForEach(value.simulatorStreamRows) { panel in
                    Button { actions.selectSimulatorStream(panel.id) } label: {
                        Label(
                            panel.label,
                            systemImage: panel.id == value.activeSimulatorStreamPanelID
                                ? "checkmark.circle.fill"
                                : "iphone"
                        )
                    }
                    .accessibilityIdentifier("SimulatorStreamMenuItem-\(panel.id)")
                }
            }
        }

        if value.supportsBrowserStream {
            if !value.browserStreamRows.isEmpty {
                Section(L10n.string("mobile.browserStream.menuTitle", defaultValue: "Mac Browsers")) {
                    ForEach(value.browserStreamRows) { panel in
                        Button { actions.selectBrowserStream(panel.id) } label: {
                            Label(
                                panel.label,
                                systemImage: panel.id == value.activeBrowserStreamPanelID
                                    ? "checkmark.circle.fill"
                                    : "globe"
                            )
                        }
                        .accessibilityIdentifier("BrowserStreamMenuItem-\(panel.id)")
                    }
                }
            }
        } else {
            Section(L10n.string("mobile.browserStream.menuTitle", defaultValue: "Mac Browsers")) {
                Label(
                    L10n.string("mobile.macUpdateHint.browserStream", defaultValue: "Update cmux on your Mac to stream browser panes"),
                    systemImage: "arrow.down.circle"
                )
                .accessibilityIdentifier("BrowserStreamMacUpdateHint")
            }
        }

        Section {
            Button(action: actions.createWorkspace) {
                Label(
                    L10n.string("mobile.workspace.new", defaultValue: "New Workspace"),
                    systemImage: "plus.square.on.square"
                )
            }
            .disabled(!value.canCreateWorkspace)
            .accessibilityIdentifier("MobileNewWorkspaceMenuItem")

            if value.canCreateTerminal {
                Button(action: actions.createTerminal) {
                    Label(
                        value.sshTabLayout?.newTerminalTitle
                            ?? L10n.string("mobile.terminal.new", defaultValue: "New Terminal"),
                        systemImage: "plus"
                    )
                }
                .accessibilityIdentifier("MobileNewTerminalMenuItem")
            }

            Button(action: actions.openBrowser) {
                Label(
                    L10n.string("mobile.browser.new", defaultValue: "New Browser"),
                    systemImage: value.hasActiveBrowser ? "checkmark.circle.fill" : "globe"
                )
            }
            .accessibilityIdentifier("MobileNewBrowserMenuItem")
        }

        #if canImport(UIKit)
        Section {
            if !value.hasActiveBrowser {
                Button(action: actions.openTextSheet) {
                    Label(
                        L10n.string("mobile.terminal.viewAsText", defaultValue: "View as Text"),
                        systemImage: "doc.plaintext"
                    )
                }
                .accessibilityIdentifier("MobileViewAsTextMenuItem")
            }

            #if DEBUG
            Button(action: actions.copyDebugLogs) {
                Label(
                    L10n.string("mobile.debug.copyLogs", defaultValue: "Copy Debug Logs"),
                    systemImage: "doc.on.clipboard"
                )
            }
            .accessibilityIdentifier("MobileCopyDebugLogsMenuItem")
            #endif

            Button(action: actions.sendFeedback) {
                Label(
                    L10n.string("mobile.feedback.send", defaultValue: "Send Feedback"),
                    systemImage: "paperplane"
                )
            }
            .accessibilityIdentifier("MobileSendFeedbackMenuItem")
        }
        #endif
    }

    /// SSH tmux / cmux-tui workspaces (PRD D32): one section per tmux window
    /// or cmux-tui screen, its pane/tab terminals as rows (a divider between
    /// panes, and each row names its pane when the section has several), and
    /// the section's own action last (HIG Menus: group related items,
    /// section titles name the group).
    @ViewBuilder
    private func groupedTerminalSections(_ layout: MobileSSHTabLayout) -> some View {
        ForEach(layout.sections) { section in
            Section(section.title) {
                ForEach(section.rows) { row in
                    if row.startsPane {
                        Divider()
                    }
                    let id = MobileTerminalPreview.ID(rawValue: row.id)
                    Toggle(isOn: Binding(
                        get: { value.checkedRowID == .terminal(id) },
                        set: { _ in actions.selectTerminal(id) }
                    )) {
                        // Title, then subtitle: UIMenu renders the second
                        // Text as the item's subtitle.
                        Text(row.title)
                        if let paneLabel = row.paneLabel {
                            Text(paneLabel)
                        }
                        Image(systemName: "terminal")
                    }
                    .accessibilityIdentifier("MobileTerminalMenuItem-\(row.id)")
                }
                if section.canAddTab {
                    Button {
                        actions.createSSHTab(section.id)
                    } label: {
                        Label(layout.sectionActionTitle, systemImage: layout.sectionActionSystemImage)
                    }
                    .accessibilityIdentifier("MobileSSHSectionAction-\(section.id)")
                }
            }
        }
    }
}
