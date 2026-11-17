import AppKit
import CmuxNextDesign
import CmuxNextIcons
import SwiftUI

/// The Density Playground's window content: the density picker and its actions on top, the values of one group
/// (Vertical tabs, Horizontal tabs, Other) below, each with a slider, an exact field and a reset.
///
/// It draws at fixed sizes, not the density's: the window must stay still while the sizes it tunes change under it.
struct DensityPlaygroundView: View {
    @Bindable var model: DensityPlaygroundModel
    @State private var group: DensityTokenCatalog.Group = .verticalTabs
    @State private var changedOnly = false
    @State private var nameText = ""
    @State private var confirmingDelete = false
    @State private var flash: String?
    @FocusState private var nameFocused: Bool

    /// The window's own sizes (a 4 pt grid), apart from the density being tuned.
    enum Size {
        static let pad: CGFloat = 16
        static let gap: CGFloat = 8
        static let rowHeight: CGFloat = 28
        static let slider: CGFloat = 168
        static let field: CGFloat = 56
        static var body: Font { font(TypeScale.Base.detail) }
        static var label: Font { font(TypeScale.Base.detail) }
        static var labelChanged: Font { font(TypeScale.Base.detail, TypeScale.emphasis) }
        static var caption: Font { font(TypeScale.Base.caption) }
        static var section: Font { font(TypeScale.Base.caption, TypeScale.emphasis) }

        /// The type scale's base sizes, not the density's: the window keeps its text while the density changes.
        private static func font(_ size: CGFloat, _ weight: NSFont.Weight = TypeScale.regular) -> Font {
            Font(Typography.system(size: size, weight: weight))
        }
    }

    var body: some View {
        content(theme: SettingsTheme.shared.tokens)
    }

    /// The panel; `theme` is read in `body` only so a theme change redraws it.
    private func content(theme _: some Any) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(SettingsStyle.separator).frame(height: 1)
            list
        }
        .tint(SettingsStyle.tint)
        .foregroundStyle(SettingsStyle.text)
        .font(Size.body)
        .controlSize(.small)
        .onAppear { nameText = model.name(model.draft) }
        .onChange(of: model.draft.id) {
            nameText = model.name(model.draft)
            confirmingDelete = false
        }
        .onChange(of: model.draft) { flash = nil }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Size.gap) {
            HStack(spacing: Size.gap) {
                Text(DensityPlaygroundStrings.density)
                Picker(DensityPlaygroundStrings.density, selection: Binding(get: { model.draft.id }, set: { model.select(id: $0) })) {
                    ForEach(model.densities) { density in
                        Text(model.name(density)).tag(density.id)
                    }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                .accessibilityIdentifier("cmux.densityPlayground.picker")
                TextField(DensityPlaygroundStrings.name, text: $nameText)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit { model.rename(nameText) }
                    .onChange(of: nameFocused) { if !nameFocused { model.rename(nameText) } }
                    .accessibilityLabel(DensityPlaygroundStrings.name)
                    .accessibilityIdentifier("cmux.densityPlayground.name")
            }
            HStack(spacing: Size.gap) {
                Button(DensityPlaygroundStrings.duplicate) { model.duplicate() }
                    .accessibilityIdentifier("cmux.densityPlayground.duplicate")
                Button(DensityPlaygroundStrings.copyJSON) { copy(model.exportJSON) }
                    .accessibilityIdentifier("cmux.densityPlayground.copyJSON")
                Button(DensityPlaygroundStrings.copySwift) { copy(model.exportSwift) }
                Button(DensityPlaygroundStrings.pasteJSON) {
                    model.importJSON(NSPasteboard.general.string(forType: .string) ?? "")
                }
                .accessibilityIdentifier("cmux.densityPlayground.pasteJSON")
                Spacer(minLength: 0)
                Button(DebugSettingsStrings.resetAll) { model.resetAll() }
                    .disabled(model.isBuiltIn || model.changedCount == 0)
                    .accessibilityIdentifier("cmux.densityPlayground.resetAll")
                if !model.isBuiltIn {
                    // Two presses, no dialog: the first arms it and names what goes.
                    Button(confirmingDelete ? DensityPlaygroundStrings.confirmDelete(model.name(model.draft)) : DensityPlaygroundStrings.delete) {
                        if confirmingDelete { model.deleteDraft() } else { confirmingDelete = true }
                    }
                    .foregroundStyle(confirmingDelete ? Color.red : SettingsStyle.text)
                    .accessibilityIdentifier("cmux.densityPlayground.delete")
                }
            }
            .buttonStyle(SettingsButtonStyle())
            HStack(spacing: Size.gap) {
                Text(statusLine)
                    .font(Size.caption).foregroundStyle(model.notice == nil ? SettingsStyle.secondary : Color.red)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !model.isBuiltIn {
                    Text(model.hasUnsavedChanges ? DensityPlaygroundStrings.saving : DensityPlaygroundStrings.saved)
                        .font(Size.caption).foregroundStyle(SettingsStyle.tertiary)
                        .monospacedDigit()
                }
            }
            HStack(spacing: Size.gap) {
                Picker("", selection: $group) {
                    ForEach(DensityTokenCatalog.Group.allCases, id: \.self) { group in
                        Text(DensityPlaygroundStrings.group(group)).tag(group)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .themedHelp("⌘1 ⌘2 ⌘3")
                .background { groupShortcuts }
                .accessibilityIdentifier("cmux.densityPlayground.group")
                Spacer(minLength: 0)
                Toggle(DensityPlaygroundStrings.changedOnly, isOn: $changedOnly)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("cmux.densityPlayground.changedOnly")
            }
        }
        .padding(.horizontal, Size.pad)
        // The titlebar is transparent and the content runs under it.
        .padding(.top, 36)
        .padding(.bottom, Size.gap + 4)
    }

    /// Command-1, -2 and -3 pick a group from the keyboard (a segmented control takes no focus by default).
    private var groupShortcuts: some View {
        ForEach(Array(DensityTokenCatalog.Group.allCases.enumerated()), id: \.offset) { index, item in
            Button("") { group = item }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    private var statusLine: String {
        if let flash { return flash }
        if let notice = model.notice { return notice }
        if model.isBuiltIn { return DensityPlaygroundStrings.builtInHint }
        return DensityPlaygroundStrings.changedCount(model.changedCount, base: model.name(model.base))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        // Says so until the next change (no timer: the window wakes nothing while idle).
        flash = DensityPlaygroundStrings.copied
    }

    // MARK: Values

    private var sections: [(title: String, entries: [DensityTokenCatalog.Entry])] {
        var result: [(String, [DensityTokenCatalog.Entry])] = []
        for entry in model.entries where entry.group == group && (!changedOnly || model.isChanged(entry)) {
            if let last = result.indices.last, result[last].0 == entry.section {
                result[last].1.append(entry)
            } else {
                result.append((entry.section, [entry]))
            }
        }
        return result
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sections, id: \.title) { section in
                    Text(section.title)
                        .font(Size.section).foregroundStyle(SettingsStyle.secondary)
                        .padding(.horizontal, Size.pad)
                        .padding(.top, Size.pad - 4)
                        .padding(.bottom, 4)
                    ForEach(section.entries) { entry in
                        DensityPlaygroundRow(model: model, entry: entry)
                    }
                }
            }
            .padding(.bottom, Size.gap)
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("cmux.densityPlayground.list")
    }
}

/// One value: a dot when it differs from the base, its label (help on hover), a slider, the exact number and a reset.
private struct DensityPlaygroundRow: View {
    let model: DensityPlaygroundModel
    let entry: DensityTokenCatalog.Entry
    @State private var text = ""
    @FocusState private var editing: Bool
    typealias Size = DensityPlaygroundView.Size

    var body: some View {
        let changed = model.isChanged(entry)
        let value = model.value(entry) ?? entry.range.lowerBound
        HStack(spacing: Size.gap) {
            Circle().fill(SettingsStyle.tint).frame(width: 6, height: 6).opacity(changed ? 1 : 0)
                .accessibilityHidden(true)
            Text(entry.label)
                .font(changed ? Size.labelChanged : Size.label)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .themedHelp(help)
            Slider(value: Binding(get: { min(max(value, entry.range.lowerBound), entry.range.upperBound) },
                                  set: { model.set(entry, to: $0) }), in: entry.range)
                .frame(width: Size.slider)
                .accessibilityLabel(entry.label)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: Size.field)
                .focused($editing)
                .onSubmit(commit)
                .onChange(of: editing) { if !editing { commit() } }
                .accessibilityLabel(entry.label)
            Text(entry.unit == .factor ? "×" : "pt")
                .font(Size.caption).foregroundStyle(SettingsStyle.tertiary)
                .frame(width: 14, alignment: .leading)
            Button { model.reset(entry) } label: { Icon(.actionUndo, size: 12) }
                .buttonStyle(.cmuxPressFill)
                .foregroundStyle(SettingsStyle.secondary)
                .accessibilityLabel(SettingsWindowStrings.reset)
                .opacity(changed ? 1 : 0)
                .disabled(!changed)
        }
        .frame(height: Size.rowHeight)
        .padding(.horizontal, Size.pad)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cmux.densityPlayground.row.\(entry.key)")
        .onAppear { text = DensityPlaygroundModel.format(value) }
        .onChange(of: value) { if !editing { text = DensityPlaygroundModel.format(value) } }
    }

    private var help: String {
        guard let base = model.baseValue(entry) else { return entry.help }
        return "\(entry.help) \(model.name(model.base)): \(DensityPlaygroundModel.format(base))."
    }

    private func commit() {
        let typed = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let number = Double(typed) else {
            text = DensityPlaygroundModel.format(model.value(entry) ?? entry.range.lowerBound)
            return
        }
        // Leaving a field as shown writes nothing (it shows a rounded value).
        if let current = model.value(entry), typed == DensityPlaygroundModel.format(current) || abs(current - number) < 0.0001 { return }
        model.set(entry, to: number)
        text = DensityPlaygroundModel.format(model.value(entry) ?? number)
    }
}
