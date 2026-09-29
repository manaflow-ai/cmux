import CmuxNextDesign
import SwiftUI

/// Layout constants for the palette.
enum PaletteMetrics {
    static let width: CGFloat = 720
    static let headerHeight: CGFloat = 58
    static let listHeight: CGFloat = 372
    static let footerHeight: CGFloat = 40
    static let rowHeight: CGFloat = 40
    static let cornerRadius: CGFloat = 18
    static let rowCornerRadius: CGFloat = 9
    static let listInset: CGFloat = 8
    /// Transparent margin around the panel so the shadow and the open
    /// animation are never clipped by the window.
    static let shadowMargin: CGFloat = 40

    static var height: CGFloat { headerHeight + listHeight + footerHeight + 2 }
    static var windowSize: CGSize {
        CGSize(width: width + 2 * shadowMargin, height: height + 2 * shadowMargin)
    }
}

/// The palette surface: search header, sectioned results, footer, and the
/// Actions menu overlay, on one Liquid Glass panel.
struct PaletteRootView: View {
    @Bindable var model: PaletteModel
    @FocusState private var fieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassEffectContainer {
            VStack(spacing: 0) {
                header
                hairline
                results
                hairline
                footer
            }
            .frame(width: PaletteMetrics.width, height: PaletteMetrics.height)
            .glassEffect(.regular.tint(Color(nsColor: Palette.glassTint)), in: .rect(cornerRadius: PaletteMetrics.cornerRadius))
            .overlay(alignment: .bottomTrailing) {
                if let menu = model.actionsMenu {
                    PaletteActionsMenuView(model: model, menu: menu)
                        .padding(.trailing, 10)
                        .padding(.bottom, PaletteMetrics.footerHeight + 6)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .scale(scale: 0.94, anchor: .bottomTrailing).combined(with: .opacity)
                        )
                }
            }
            .animation(reduceMotion ? .easeOut(duration: 0.1) : .spring(duration: 0.2, bounce: 0.12), value: model.actionsMenu?.itemID)
        }
        .shadow(color: .black.opacity(0.22), radius: 28, y: 14)
        .scaleEffect(model.isPresented || reduceMotion ? 1 : 0.965, anchor: .top)
        .opacity(model.isPresented ? 1 : 0)
        .padding(PaletteMetrics.shadowMargin)
        .frame(width: PaletteMetrics.windowSize.width, height: PaletteMetrics.windowSize.height, alignment: .top)
        .onChange(of: model.pageToken, initial: true) { fieldFocused = true }
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color(nsColor: Palette.separator))
            .frame(height: 1)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            if let last = model.breadcrumbs.last {
                Button {
                    model.pop()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text(last)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Capsule().fill(Color(nsColor: Palette.selectionFill)))
                }
                .buttonStyle(.plain)
                .help(PaletteStrings.back)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            TextField("", text: $model.query, prompt: Text(model.placeholder))
                .textFieldStyle(.plain)
                .font(.system(size: 20))
                .focused($fieldFocused)
                .focusEffectDisabled()
                .accessibilityIdentifier("palette.search")
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: PaletteMetrics.headerHeight)
    }

    // MARK: Results

    @ViewBuilder
    private var results: some View {
        if model.sections.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(PaletteStrings.noResults)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(PaletteStrings.noResultsHint)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: PaletteMetrics.listHeight)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.sections) { section in
                            if !section.title.isEmpty {
                                Text(section.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 10)
                                    .padding(.top, 10)
                                    .padding(.bottom, 4)
                            }
                            ForEach(section.rows) { row in
                                PaletteRowView(
                                    row: row,
                                    isSelected: row.id == model.selectedRowID,
                                    isHovered: row.id == model.hoveredRowID
                                )
                                .id(row.id)
                                .onHover { inside in
                                    if inside {
                                        model.hover(row.id)
                                    } else if model.hoveredRowID == row.id {
                                        model.hover(nil)
                                    }
                                }
                                .onTapGesture { model.activate(rowID: row.id) }
                            }
                        }
                    }
                    .padding(PaletteMetrics.listInset)
                }
                .scrollIndicators(.automatic)
                .frame(height: PaletteMetrics.listHeight)
                .onChange(of: model.scrollRequest) {
                    guard let id = model.selectedRowID else { return }
                    proxy.scrollTo(id)
                }
            }
            // Result changes swap rows in place; never animate them, so
            // typing never flickers or slides.
            .transaction { $0.animation = nil }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: model.pageSymbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(model.pageTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 12)
            if let primary = model.primaryTitle {
                Button {
                    model.handle(.submit)
                } label: {
                    HStack(spacing: 6) {
                        Text(primary)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                        KeycapsView(keycaps: ["↩"])
                    }
                }
                .buttonStyle(.plain)
                Rectangle()
                    .fill(Color(nsColor: Palette.separator))
                    .frame(width: 1, height: 16)
            }
            Button {
                model.handle(.toggleActions)
            } label: {
                HStack(spacing: 6) {
                    Text(PaletteStrings.actions)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    KeycapsView(keycaps: ["⌘", "K"])
                }
            }
            .buttonStyle(.plain)
            .disabled(model.selectedItem?.isEnabled != true)
        }
        .padding(.horizontal, 14)
        .frame(height: PaletteMetrics.footerHeight)
    }
}

/// One result row. Selection and hover are gray fills, never accent blue.
struct PaletteRowView: View {
    let row: PaletteRow
    let isSelected: Bool
    let isHovered: Bool

    var body: some View {
        let item = row.item
        HStack(spacing: 12) {
            Image(systemName: item.symbol ?? "command")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(width: 22, height: 22)
            HStack(spacing: 8) {
                Text(highlightedTitle)
                    .font(.system(size: 14))
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            if let accessory = item.accessory {
                Text(accessory)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if let keycaps = item.keycaps {
                KeycapsView(keycaps: keycaps)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: PaletteMetrics.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: PaletteMetrics.rowCornerRadius, style: .continuous)
                .fill(fill)
        }
        .opacity(item.isEnabled ? 1 : 0.45)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var fill: Color {
        if isSelected { return Color(nsColor: Palette.selectionFill) }
        if isHovered { return Color(nsColor: Palette.hoverFill) }
        return .clear
    }

    /// Matched characters in full primary color and semibold; the rest
    /// slightly muted, so the match reads without a colored highlight.
    private var highlightedTitle: AttributedString {
        var text = AttributedString(row.item.title)
        guard !row.highlights.isEmpty else { return text }
        text.foregroundColor = .primary.opacity(0.82)
        let scalars = text.unicodeScalars
        var remaining = Set(row.highlights)
        var offset = 0
        var index = scalars.startIndex
        while index < scalars.endIndex, !remaining.isEmpty {
            let next = scalars.index(after: index)
            if remaining.remove(offset) != nil {
                text[index..<next].foregroundColor = .primary
                text[index..<next].font = .system(size: 14, weight: .semibold)
            }
            index = next
            offset += 1
        }
        return text
    }
}

/// Shortcut badges, one per key.
struct KeycapsView: View {
    let keycaps: [String]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keycaps.enumerated()), id: \.offset) { _, cap in
                Text(cap)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 20, minHeight: 20)
                    .padding(.horizontal, cap.count > 1 ? 5 : 0)
                    .background {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color(nsColor: Palette.selectionFill))
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keycaps.joined())
    }
}

/// The Cmd-K menu: every command of the selected item, filterable by typing.
struct PaletteActionsMenuView: View {
    let model: PaletteModel
    let menu: PaletteActionsMenuState

    var body: some View {
        let visible = menu.visibleCommands
        VStack(alignment: .leading, spacing: 0) {
            Text(menu.itemTitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
            VStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, command in
                    HStack(spacing: 10) {
                        Image(systemName: command.symbol ?? "circle")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 18)
                            .foregroundStyle(command.isDestructive ? Color.red.opacity(0.85) : .secondary)
                        Text(command.title)
                            .font(.system(size: 13))
                            .foregroundStyle(command.isDestructive ? Color.red.opacity(0.9) : .primary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if index == 0 {
                            KeycapsView(keycaps: ["↩"])
                        } else if index == 1, visible.count > 1, command.id == model.selectedItem?.alternate?.id {
                            KeycapsView(keycaps: ["⌘", "↩"])
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 32)
                    .background {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(index == menu.selectedIndex ? Color(nsColor: Palette.selectionFill) : .clear)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.runActionsMenuCommand(at: index) }
                }
            }
            .padding(.horizontal, 4)
            Rectangle()
                .fill(Color(nsColor: Palette.separator))
                .frame(height: 1)
                .padding(.top, 4)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text(menu.filter.isEmpty ? PaletteStrings.searchActionsPlaceholder : menu.filter)
                    .font(.system(size: 12))
                    .foregroundStyle(menu.filter.isEmpty ? .tertiary : .primary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
        }
        .frame(width: 300)
        .glassEffect(.regular.tint(Color(nsColor: Palette.glassTint)), in: .rect(cornerRadius: 12))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
    }
}
