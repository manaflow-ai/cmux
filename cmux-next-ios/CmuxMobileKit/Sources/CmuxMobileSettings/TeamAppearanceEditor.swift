#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import SwiftUI
import UIKit

private let theme = CmuxMobileTheme.standard

/// Team color and icon editor (SPEC 3.4): an opaque sheet with a glass X,
/// centered "Team appearance", a 72 pt preview, the 13 color swatches and
/// Transparent (7 columns, never under the keyboard), the icon control and a
/// docked "Done". Transparent (no background) is offered only with a custom
/// icon; removing the icon falls back to the last color chosen. The icon is Automatic (the team's first letter), Custom (one
/// character: the field opens on the emoji keyboard, and the globe key still
/// reaches letters, digits and symbols) or None (color only). Changes apply
/// through `onSave`.
public struct TeamAppearanceEditor: View {
    let team: Team
    let onSave: (TeamAppearance) -> Void
    @State private var appearance: TeamAppearance
    @State private var mode: GlyphMode
    @State private var customText: String
    @State private var customFocused = false
    /// Transparent as last chosen here: replacing the icon (which passes
    /// through no icon) keeps it, while Done without an icon saves the color.
    @State private var wantsTransparent: Bool
    @State private var detent: PresentationDetent
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    enum GlyphMode: String, CaseIterable, Identifiable {
        case automatic, custom, none
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .automatic: "Automatic"
            case .custom: "Custom"
            case .none: "None"
            }
        }
    }

    /// The sheet's opaque background (grouped gray in light, raised in dark)
    /// and the icon box on it.
    private static let sheetBackground = CmuxMobileColorToken(dark: CmuxMobileRGBA(hex: "#1C1C1E"), light: CmuxMobileRGBA(hex: "#F2F2F7"))
    private static let boxBackground = CmuxMobileColorToken(dark: CmuxMobileRGBA(hex: "#2C2C2E"), light: CmuxMobileRGBA(hex: "#FFFFFF"))
    private static let compactDetent = PresentationDetent.height(640)

    public init(team: Team, onSave: @escaping (TeamAppearance) -> Void) {
        self.team = team
        self.onSave = onSave
        _appearance = State(initialValue: team.appearance)
        _wantsTransparent = State(initialValue: team.appearance.isTransparent)
        _detent = State(initialValue: Self.compactDetent)
        switch team.appearance.glyph {
        case .automatic:
            _mode = State(initialValue: .automatic)
            _customText = State(initialValue: "")
        case .custom(let value):
            _mode = State(initialValue: .custom)
            _customText = State(initialValue: value)
        case .none:
            _mode = State(initialValue: .none)
            _customText = State(initialValue: "")
        }
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
            // Pinned above the scrolling Icon controls: the preview, the
            // "Color" header and the grid stay whole and in view while the
            // keyboard is up (the preview smaller then). Only Icon scrolls.
            VStack(spacing: 0) {
                preview
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                sectionHeader("Color").padding(.top, 16)
                colorGrid.padding(.top, 8)
            }
            .padding(.horizontal, theme.metrics.sideMargin)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        iconSection.padding(.top, 24).padding(.bottom, 16)
                    }
                    .padding(.horizontal, theme.metrics.sideMargin)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: customFocused) { _, focused in
                    guard focused else { return }
                    withAnimation(theme.motion.smooth.animation) { proxy.scrollTo("character", anchor: .bottom) }
                }
            }
            }
            // Done docks only while the keyboard is down: it never sits over
            // the grid. With the keyboard up, picking a character (or the
            // keyboard's Done key) dismisses it and Done comes back.
            .safeAreaInset(edge: .bottom) {
                if !customFocused {
                    PrimaryCapsule("Done") {
                        onSave(appearance)
                        dismiss()
                    }
                    .padding(.horizontal, theme.metrics.sideMargin)
                    .padding(.bottom, 8)
                    .transition(.opacity)
                }
            }
            .background(Self.sheetBackground.color.ignoresSafeArea())
            .navigationTitle("Team appearance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [Self.compactDetent, .large], selection: $detent)
        .presentationBackground(Self.sheetBackground.color)
        .cmuxMobileNeutralControlTint()
        .cmuxMobileSensoryFeedback(.selection, trigger: appearance)
        .onChange(of: customFocused) { _, focused in
            // The keyboard needs the room: the sheet grows while typing.
            if focused { detent = .large }
        }
        .onAppear { if typeSize.isAccessibilitySize { detent = .large } }
        #if DEBUG
        .onChange(of: DemoDirector.shared.serial) {
            switch DemoDirector.shared.command {
            case .editorColor(let hex):
                appearance.choose(colorHex: hex)
                wantsTransparent = false
            case .editorEmoji(let emoji):
                appearance.emoji = emoji
                if wantsTransparent { appearance.isTransparent = true }
            case .editorDone:
                onSave(appearance)
                dismiss()
            default: break
            }
        }
        #endif
    }

    // MARK: Preview and color

    /// Custom with nothing picked yet previews the color alone, so it never
    /// shows Automatic's letter as if it were chosen.
    private var preview: some View {
        let emoji = mode == .custom && customText.isEmpty ? "" : appearance.emoji
        let size: CGFloat = customFocused ? 48 : 72
        return TeamAvatar(name: team.name, colorHex: appearance.colorHex, emoji: emoji, size: size, transparent: appearance.isTransparent)
            .clipShape(.rect(cornerRadius: size * 20 / 72, style: .continuous))
            .animation(theme.motion.snap.animation, value: appearance)
            .animation(theme.motion.smooth.animation, value: customFocused)
    }

    /// 13 swatches and Transparent in 7 columns of 44 pt (7 x 44 + 6 x 6 = 344 pt).
    private var colorGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 6), count: 7), spacing: 10) {
            ForEach(theme.colors.teamPalette) { color in
                let selected = !appearance.isTransparent && color.dark.caseInsensitiveCompare(appearance.colorHex) == .orderedSame
                Button {
                    appearance.choose(colorHex: color.dark)
                    wantsTransparent = false
                } label: {
                    Circle()
                        .fill(color.token)
                        .frame(width: 32, height: 32)
                        .padding(3)
                        .overlay {
                            Circle().strokeBorder(theme.colors.label, lineWidth: 3).opacity(selected ? 1 : 0)
                        }
                        .frame(width: 44, height: 44)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(color.name))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            transparentSwatch
        }
    }

    /// No background: an outlined circle crossed by a slash. Dimmed and
    /// disabled until the team has a custom icon.
    private var transparentSwatch: some View {
        let available = appearance.canBeTransparent
        let selected = appearance.isTransparent
        return Button {
            appearance.isTransparent = true
            wantsTransparent = true
        } label: {
            ZStack {
                Circle().strokeBorder(theme.colors.label2, lineWidth: 1.5)
                Rectangle()
                    .fill(theme.colors.label2)
                    .frame(width: 1.5, height: 30)
                    .rotationEffect(.degrees(45))
            }
            .frame(width: 32, height: 32)
            .clipShape(.circle)
            .padding(3)
            .overlay {
                Circle().strokeBorder(theme.colors.label, lineWidth: 3).opacity(selected ? 1 : 0)
            }
            .frame(width: 44, height: 44)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.35)
        .accessibilityLabel(Text("Transparent"))
        .accessibilityHint(available ? Text("Shows the icon with no background.") : Text("Choose a custom icon first."))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("teamAppearance.transparent")
    }

    // MARK: Icon

    private var iconSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Icon")
            VStack(spacing: 0) {
                modePicker
                if mode == .custom {
                    Divider().padding(.leading, 16)
                    characterWell
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity)
                        .id("character")
                        .transition(.opacity)
                }
            }
            .background(Self.boxBackground, in: .rect(cornerRadius: theme.metrics.inputRadius, style: .continuous))
            Text(footer)
                .font(theme.type.meta)
                .foregroundStyle(theme.colors.label2)
                .padding(.horizontal, 16)
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(theme.motion.snap.animation, value: mode)
        .onChange(of: mode) { _, newMode in
            applyGlyph()
            customFocused = newMode == .custom && customText.isEmpty
        }
    }

    /// Segmented at standard sizes; at accessibility sizes, where a segmented
    /// control keeps its small type, a checklist.
    @ViewBuilder private var modePicker: some View {
        if typeSize.isAccessibilitySize {
            VStack(spacing: 0) {
                ForEach(GlyphMode.allCases) { option in
                    Button {
                        mode = option
                    } label: {
                        HStack {
                            Text(option.title).font(theme.type.rowTitle).foregroundStyle(theme.colors.label)
                            Spacer(minLength: 8)
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(theme.colors.label)
                                .opacity(mode == option ? 1 : 0)
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: theme.metrics.settingsRowHeight)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(mode == option ? .isSelected : [])
                    if option != GlyphMode.allCases.last { Divider().padding(.leading, 16) }
                }
            }
            .accessibilityIdentifier("teamAppearance.iconMode")
        } else {
            Picker("Icon", selection: $mode) {
                ForEach(GlyphMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(12)
            .accessibilityIdentifier("teamAppearance.iconMode")
        }
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(theme.type.meta)
            .foregroundStyle(theme.colors.label2)
            .padding(.leading, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The character, 34 pt in a 56 pt well; empty, a dashed well with a
    /// smiley. Tapping it opens the emoji keyboard.
    private var characterWell: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(theme.colors.separator, style: StrokeStyle(lineWidth: 1, dash: customText.isEmpty ? [4, 3] : []))
                .opacity(customText.isEmpty || customFocused ? 1 : 0)
            if customText.isEmpty {
                Image(systemName: "face.smiling")
                    .font(.system(size: 24))
                    .foregroundStyle(theme.colors.label3)
                    .allowsHitTesting(false)
            }
            EmojiCharacterField(text: $customText, isFocused: $customFocused)
                .accessibilityLabel(Text("Character"))
                .accessibilityValue(Text(verbatim: customText))
                .accessibilityIdentifier("teamAppearance.character")
        }
        .frame(width: 56, height: 56)
        .contentShape(.rect)
        .onTapGesture { customFocused = true }
        .onChange(of: customText) { old, new in
            let kept = Self.keptCharacter(old: old, new: new) ?? ""
            if kept != new { customText = kept }
            applyGlyph()
            // One character is all it holds: picking one puts the keyboard away.
            if !kept.isEmpty, kept != old { customFocused = false }
        }
    }

    private var footer: LocalizedStringKey {
        switch mode {
        case .automatic: "Shows the first letter of \(team.name)."
        case .custom: "Pick an emoji, or type a letter, number or symbol."
        case .none: "Shows the color only."
        }
    }

    private func applyGlyph() {
        switch mode {
        case .automatic: appearance.glyph = .automatic
        case .none: appearance.glyph = .none
        // An empty custom field previews (and saves) as automatic.
        case .custom: appearance.glyph = customText.isEmpty ? .automatic : .custom(customText)
        }
        // A no-op without an icon (the color shows); back on with a new one.
        if wantsTransparent { appearance.isTransparent = true }
    }

    /// The one character the field keeps after an edit: the grapheme just
    /// typed (wherever the cursor was), replacing the previous one; nil when
    /// the field was cleared or only whitespace was typed.
    static func keptCharacter(old: String, new: String) -> String? {
        guard new.count > old.count else { return TeamGlyph.character(from: new) }
        let added = new.hasPrefix(old) ? String(new.dropFirst(old.count))
            : new.hasSuffix(old) ? String(new.dropLast(old.count))
            : new
        return TeamGlyph.character(from: added) ?? TeamGlyph.character(from: old)
    }
}

/// A one-character field that opens on the emoji keyboard, with no
/// predictive bar or shortcuts. The globe key still switches to letters.
struct EmojiCharacterField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool

    final class Field: UITextField {
        override var textInputMode: UITextInputMode? {
            UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
        }

        // Without a context identifier iOS restores the last keyboard used here.
        override var textInputContextIdentifier: String? { "" }
    }

    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.delegate = context.coordinator
        field.font = .systemFont(ofSize: 34)
        field.textAlignment = .center
        field.textColor = .label
        field.tintColor = .clear
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.autocapitalizationType = .none
        field.smartInsertDeleteType = .no
        field.inlinePredictionType = .no
        field.textContentType = nil
        field.returnKeyType = .done
        field.inputAssistantItem.leadingBarButtonGroups = []
        field.inputAssistantItem.trailingBarButtonGroups = []
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        if isFocused, !field.isFirstResponder {
            Task { @MainActor in field.becomeFirstResponder() }
        } else if !isFocused, field.isFirstResponder {
            Task { @MainActor in field.resignFirstResponder() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: EmojiCharacterField

        init(parent: EmojiCharacterField) {
            self.parent = parent
        }

        @objc func changed(_ field: UITextField) {
            parent.text = field.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            if parent.isFocused { parent.isFocused = false }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.isFocused = false
            return false
        }
    }
}
#endif
