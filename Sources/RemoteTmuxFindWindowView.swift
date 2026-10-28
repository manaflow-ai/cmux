import CmuxTextMatching
import SwiftUI

/// The find-window panel, hosted in the command palette overlay.
///
/// The query field is the command palette's own search field, so arrow keys,
/// Return and Escape behave the way they do in the palette.
struct RemoteTmuxFindWindowView: View {
    @Bindable var model: RemoteTmuxFindWindowModel
    let onDismiss: () -> Void
    @State private var isQueryFocused = true

    var body: some View {
        VStack(spacing: 0) {
            header
            optionsRow
            if model.isReadingHistory {
                ProgressView(
                    value: Double(model.settledPaneCount),
                    total: Double(max(1, model.paneCount))
                )
                .progressViewStyle(.linear)
                .controlSize(.small)
                .padding(.horizontal, 12)
                .safeHelp(String(
                    localized: "remoteTmux.findWindow.reading.help",
                    defaultValue: "Reading each pane's tmux history"
                ))
            }
            Divider()
            resultList
            footer
        }
        .onExitCommand(perform: onDismiss)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.and.text.magnifyingglass")
                .foregroundStyle(.secondary)
            CommandPaletteSearchFieldRepresentable(
                placeholder: String(
                    localized: "remoteTmux.findWindow.placeholder",
                    defaultValue: "Find window names, pane titles and pane contents"
                ),
                text: $model.query,
                isFocused: $isQueryFocused,
                onSubmit: { model.activateSelection() },
                onEscape: onDismiss,
                onMoveSelection: { model.moveSelection(by: $0) },
                onUnhandledNavigationKey: { _ in false }
            )
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("RemoteTmuxFindWindowQueryField")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
    }

    private var optionsRow: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $model.options.matchesWindowNames) {
                Text(String(localized: "remoteTmux.findWindow.names", defaultValue: "Names"))
            }
            .safeHelp(String(localized: "remoteTmux.findWindow.names.help", defaultValue: "Match window names (tmux -N)"))
            Toggle(isOn: $model.options.matchesPaneTitles) {
                Text(String(localized: "remoteTmux.findWindow.titles", defaultValue: "Titles"))
            }
            .safeHelp(String(localized: "remoteTmux.findWindow.titles.help", defaultValue: "Match pane titles (tmux -T)"))
            Toggle(isOn: $model.options.matchesContents) {
                Text(String(localized: "remoteTmux.findWindow.contents", defaultValue: "Contents"))
            }
            .safeHelp(String(
                localized: "remoteTmux.findWindow.contents.help",
                defaultValue: "Match pane contents, including all tmux history (tmux -C)"
            ))
            Spacer(minLength: 8)
            Picker(selection: $model.options.syntax) {
                Text(String(localized: "remoteTmux.findWindow.syntax.text", defaultValue: "Text")).tag(PaneContentSyntax.text)
                Text(String(localized: "remoteTmux.findWindow.syntax.glob", defaultValue: "Glob")).tag(PaneContentSyntax.glob)
                Text(String(localized: "remoteTmux.findWindow.syntax.regex", defaultValue: "Regex")).tag(PaneContentSyntax.regex)
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .safeHelp(String(
                localized: "remoteTmux.findWindow.syntax.help",
                defaultValue: "Text: fuzzy names and titles, literal contents. Glob and Regex match everything the way tmux find-window does."
            ))
            Picker(selection: $model.options.caseMode) {
                Text(String(localized: "remoteTmux.findWindow.case.smart", defaultValue: "Smart Case")).tag(PaneContentCaseMode.smart)
                Text(String(localized: "remoteTmux.findWindow.case.ignore", defaultValue: "Ignore Case")).tag(PaneContentCaseMode.ignore)
                Text(String(localized: "remoteTmux.findWindow.case.respect", defaultValue: "Match Case")).tag(PaneContentCaseMode.respect)
            } label: {
                EmptyView()
            }
            .pickerStyle(.menu)
            .fixedSize()
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                        RemoteTmuxFindWindowRow(
                            result: result,
                            isSelected: index == model.selectedIndex,
                            onActivate: {
                                model.select(result)
                                model.activateSelection()
                            }
                        )
                        .id(result.id)
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 440)
            .onChange(of: model.selectedIndex) { _, _ in
                if let id = model.selectedResult?.id { proxy.scrollTo(id) }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if model.queryError != nil {
            footerText(String(
                localized: "remoteTmux.findWindow.invalidRegex",
                defaultValue: "The regular expression is not valid"
            ))
        } else if model.results.isEmpty, !model.isReadingHistory {
            footerText(String(localized: "remoteTmux.findWindow.noMatches", defaultValue: "No matches"))
        } else if model.unreadPaneCount > 0, !model.isReadingHistory {
            footerText(String(
                localized: "remoteTmux.findWindow.someUnread",
                defaultValue: "Some panes' history could not be read"
            ))
        }
    }

    private func footerText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }
}
