import AppKit
import CmuxNextDesign
import SwiftUI

/// Resolved colors of the page's theme scope (the host resolves them in
/// `performWithTheme` and replaces them on every theme change).
struct HistoryPageColors: Equatable {
    var background = Color.clear
    var primary = Color.primary
    var secondary = Color.secondary
    var tertiary = Color.secondary
    var hover = Color.gray.opacity(0.1)
    var selection = Color.gray.opacity(0.2)
    var separator = Color.gray.opacity(0.2)
    var danger = Color.red
}

@Observable
final class HistoryPageAppearance {
    var colors = HistoryPageColors()
}

/// The `cmux://history` page (plans/cmux-next/history.md 5.1).
struct HistoryPageView: View {
    @Bindable var model: HistoryPageModel
    let appearance: HistoryPageAppearance
    @FocusState private var searchFocused: Bool

    private var colors: HistoryPageColors { appearance.colors }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            HairlineDivider(color: colors.separator)
            if model.groups.isEmpty {
                Text(model.text.isEmpty ? HistoryStrings.empty : HistoryStrings.emptySearch)
                    .font(Font(Typography.body)).foregroundStyle(colors.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .background(colors.background)
        .onAppear { searchFocused = true }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Metrics.panelInset * 1.5) {
            titleRow
            TextField(HistoryStrings.searchPlaceholder, text: $model.text)
                .textFieldStyle(.roundedBorder).font(Font(Typography.subtitle)).focused($searchFocused)
                .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
                .onSubmit { if let entry = model.entry(id: model.selection) ?? model.flatEntries.first { model.open(entry) } }
            HistoryFilterLayout(horizontalSpacing: Metrics.panelInset * 1.5, verticalSpacing: 4) {
                ForEach(HistoryPageModel.Filter.allCases, id: \.self) { filter in
                    Button(HistoryStrings.filter(filter)) { model.filter = filter }
                        .buttonStyle(.plain).font(Font(Typography.bodyEmphasized))
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(model.filter == filter ? colors.primary : colors.secondary)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(model.filter == filter ? colors.primary : .clear)
                                .frame(height: 2)
                        }
                }
            }
            .padding(.vertical, 3)
        }
        .padding(Metrics.panelInset * 3)
    }

    private var titleRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.panelInset * 1.5) {
                title
                Spacer(minLength: 0)
                titleActions
            }
            VStack(alignment: .leading, spacing: Metrics.panelInset) {
                title
                titleActions
            }
        }
    }

    private var title: some View {
        Text(HistoryStrings.title)
            .font(Font(Typography.title))
            .foregroundStyle(colors.primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private var titleActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Metrics.panelInset * 1.5) {
                groupMenu
                clearMenu
            }
            VStack(alignment: .leading, spacing: Metrics.panelInset / 2) {
                groupMenu
                clearMenu
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var groupMenu: some View {
        Menu(HistoryStrings.groupBy) {
            ForEach(HistoryGrouping.allCases, id: \.self) { grouping in
                Button(HistoryStrings.grouping(grouping)) { model.grouping = grouping }
            }
        }
        .menuStyle(.borderlessButton).fixedSize().foregroundStyle(colors.secondary)
    }

    private var clearMenu: some View {
        Menu(HistoryStrings.clear) {
            ForEach(HistoryRange.allCases, id: \.self) { range in
                Button(HistoryStrings.range(range), role: .destructive) { model.clear(range) }
            }
        }
        .menuStyle(.borderlessButton).fixedSize().foregroundStyle(colors.secondary)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List(selection: $model.selection) {
                ForEach(model.groups) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            HistoryPageRow(entry: entry, colors: colors)
                                .tag(entry.id)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { model.open(entry) }
                                .contextMenu { HistoryPageMenu(entry: entry, model: model) }
                                .listRowBackground(model.selection == entry.id ? colors.selection : Color.clear)
                        }
                    } header: {
                        Text(title(of: group)).font(Font(Typography.header)).foregroundStyle(colors.secondary)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onChange(of: model.selection) { _, id in if let id { proxy.scrollTo(id) } }
        }
    }

    private func title(of group: HistoryGrouping.Group) -> String {
        switch model.grouping {
        case .day: Self.dayTitle(group.date, calendar: model.calendar)
        case .workspace: group.name ?? HistoryStrings.noWorkspace
        case .machine: group.name ?? HistoryStrings.thisMac
        }
    }

    static func dayTitle(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }
}
