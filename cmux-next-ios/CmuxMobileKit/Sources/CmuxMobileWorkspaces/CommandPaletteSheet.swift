#if os(iOS)
import CmuxMobileDesign
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// The command palette as a sheet over the workspace (HIG Sheets, Search fields): a search
/// field that has focus at once, then the rows that match. Return runs the first row; a picked
/// row runs once the sheet is gone (`WorkspaceTabsSource.paletteDismissed`).
struct CommandPaletteSheet: View {
    let source: WorkspaceTabsSource
    let scope: PaletteScope
    @State private var query = ""
    @State private var actions: [PaletteCommand] = []
    @FocusState private var searching: Bool

    var body: some View {
        let rows = visibleRows
        NavigationStack {
            List {
                section(PaletteCommand.Section.text, WorkspaceTabsSource.newTabFromTextTitle, rows)
                section(.actions, "Actions", rows)
                section(.tabs, scope == .tabs ? "Tabs" : "Tabs in All Workspaces", rows)
            }
            .listStyle(.insetGrouped)
            .overlay {
                if rows.isEmpty {
                    if query.isEmpty {
                        if scope == .tabs {
                            ContentUnavailableView("No Tabs", systemImage: "square.on.square",
                                                   description: Text("This team's Macs list no tabs."))
                        }
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: scope == .tabs ? "Search tabs" : "Search actions, tabs, or type a link")
            .searchFocused($searching)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .onSubmit(of: .search) {
                if let first = rows.first(where: \.isEnabled) { source.pick(first) }
            }
            .navigationTitle(scope == .tabs ? "Search Tabs" : "Command Palette")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { source.palette = nil }
                        .accessibilityIdentifier("palette.close")
                }
            }
        }
        .onAppear {
            if scope == .actions { actions = source.paletteActions() }
            searching = true
        }
        .accessibilityIdentifier("palette")
    }

    /// Text rows, then the matching actions, then tabs (every tab in Search Tabs; matches
    /// only once something is typed in the full palette).
    private var visibleRows: [PaletteCommand] {
        let text = scope == .actions ? source.paletteText(query) : []
        let matched = actions.filter { $0.matches(query) }
        let tabs = scope == .tabs || !query.trimmingCharacters(in: .whitespaces).isEmpty
            ? source.paletteTabs(matching: query.trimmingCharacters(in: .whitespaces), limit: scope == .tabs ? 200 : 30) : []
        return text + matched + tabs
    }

    @ViewBuilder
    private func section(_ kind: PaletteCommand.Section, _ title: String, _ rows: [PaletteCommand]) -> some View {
        let shown = rows.filter { $0.section == kind }
        if !shown.isEmpty {
            Section(title) {
                ForEach(shown) { command in
                    PaletteRow(command: command) { source.pick(command) }
                }
            }
        }
    }
}

/// One row: its symbol, title and where it is.
private struct PaletteRow: View {
    let command: PaletteCommand
    let pick: @MainActor () -> Void

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 14) {
                Image(systemName: command.systemImage)
                    .frame(width: 24)
                    .foregroundStyle(command.isDestructive ? Color.red : theme.colors.label2.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(command.title)
                        .foregroundStyle(command.isDestructive ? Color.red : theme.colors.label.color)
                        .lineLimit(1)
                    if let subtitle = command.subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.footnote).foregroundStyle(theme.colors.label2.color).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!command.isEnabled)
        .accessibilityIdentifier("palette.row.\(command.id)")
    }
}

/// Cmd-Shift-P (the Mac's Command Palette…) and Cmd-K open the palette from a hardware
/// keyboard. Zero-size, transparent buttons, so the keys are listed in the keyboard's
/// shortcut overlay and never take a touch or a VoiceOver stop.
struct PaletteKeys: View {
    let source: WorkspaceTabsSource

    var body: some View {
        ZStack {
            Button("Command Palette") { source.openPalette() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Command Palette") { source.openPalette() }
                .keyboardShortcut("k", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
