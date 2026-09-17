import SwiftUI

/// Header popover control for the markdown viewer's typography: a native font
/// picker, size field, max-width field, plus reset and set-as-default. Drives
/// the same `MarkdownPanel` model methods as the other markdown controls so
/// every entrypoint shares one path.
@MainActor
struct MarkdownTypographyControl: View {
    @ObservedObject var panel: MarkdownPanel
    @State private var isPresented = false
    // Loaded lazily in the background after the popover appears so it opens
    // instantly even on machines with hundreds of fonts.
    @State private var families: [String] = []
    @State private var sizeText = ""
    @State private var maxWidthText = ""
    private let labelColumnWidth: CGFloat = 66

    private var buttonLabel: String {
        String(localized: "markdown.toolbar.fontSize", defaultValue: "Font Size")
    }

    private var sizeBinding: Binding<Double> {
        Binding(get: { panel.fontSize }, set: { _ = panel.setFontSize($0) })
    }

    private var fontBinding: Binding<String> {
        Binding(get: { panel.fontFamily }, set: { _ = panel.setFontFamily($0) })
    }

    private var maxWidthBinding: Binding<Double> {
        Binding(get: { panel.maxContentWidth }, set: { _ = panel.setMaxContentWidth($0) })
    }

    /// The current selection is always tag-able, even before the full list loads.
    private var pickerFamilies: [String] {
        let current = panel.fontFamily
        if !current.isEmpty, !families.contains(current) {
            return [current] + families
        }
        return families
    }

    var body: some View {
        Button { isPresented.toggle() } label: {
            PanelHeaderIconGlyph(systemName: "textformat.size")
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .help(buttonLabel)
        .accessibilityLabel(buttonLabel)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverContent
        }
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    fieldLabel(String(localized: "markdown.typography.font", defaultValue: "Font"))
                    fontPicker
                }
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    fieldLabel(String(localized: "markdown.typography.size", defaultValue: "Size"))
                    HStack(spacing: 6) {
                        TextField(
                            String(localized: "markdown.fontSize.field", defaultValue: "Size"),
                            text: $sizeText
                        )
                        .labelsHidden()
                        .frame(width: 44)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: sizeText) {
                            applySizeTextIfValid()
                        }
                        .onSubmit {
                            commitSizeText()
                        }
                        Text(String(localized: "markdown.fontSize.unit", defaultValue: "pt"))
                            .foregroundStyle(.secondary)
                        Stepper(
                            "",
                            value: sizeBinding,
                            in: MarkdownFontSizeSettings.minimumPointSize...MarkdownFontSizeSettings.maximumPointSize,
                            step: MarkdownFontSizeSettings.stepPointSize
                        )
                        .labelsHidden()
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    fieldLabel(String(localized: "markdown.typography.maxWidth", defaultValue: "Max Width"))
                    HStack(spacing: 6) {
                        TextField(
                            String(localized: "markdown.maxWidth.field", defaultValue: "Width"),
                            text: $maxWidthText
                        )
                        .labelsHidden()
                        .frame(width: 54)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: maxWidthText) {
                            applyMaxWidthTextIfValid()
                        }
                        .onSubmit {
                            commitMaxWidthText()
                        }
                        Text(String(localized: "markdown.maxWidth.unit", defaultValue: "px"))
                            .foregroundStyle(.secondary)
                        Stepper(
                            "",
                            value: maxWidthBinding,
                            in: MarkdownMaxWidthSettings.minimumCSSPixels...MarkdownMaxWidthSettings.maximumCSSPixels,
                            step: MarkdownMaxWidthSettings.stepCSSPixels
                        )
                        .labelsHidden()
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Button(String(localized: "markdown.fontSize.reset", defaultValue: "Reset to default")) {
                    panel.resetTypography()
                }
                Button(String(localized: "markdown.typography.resetBuiltIn", defaultValue: "Reset to built-in defaults")) {
                    panel.resetTypographyToBuiltInDefaults()
                }
                Button(String(localized: "markdown.fontSize.setDefault", defaultValue: "Set as default for new viewers")) {
                    MarkdownTypographyDefaults.setDefault(
                        fontSize: panel.fontSize,
                        fontFamily: panel.fontFamily,
                        maxContentWidth: panel.maxContentWidth
                    )
                }
            }
            .buttonStyle(.link)
        }
        .padding(14)
        .frame(width: 272)
        .onAppear {
            syncDraftFieldsFromPanel()
        }
        .onChange(of: isPresented) { _, presented in
            if presented {
                syncDraftFieldsFromPanel()
            }
        }
        .onChange(of: panel.fontSize) {
            syncSizeTextFromPanel()
        }
        .onChange(of: panel.maxContentWidth) {
            syncMaxWidthTextFromPanel()
        }
        .task {
            // Load the installed font list off-main after the popover is shown.
            if families.isEmpty {
                families = await MarkdownFontFamily.availableFamilies()
            }
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(.secondary)
            .frame(width: labelColumnWidth, alignment: .leading)
    }

    private func syncDraftFieldsFromPanel() {
        syncSizeTextFromPanel()
        syncMaxWidthTextFromPanel()
    }

    private func syncSizeTextFromPanel() {
        let next = integerText(panel.fontSize)
        if sizeText != next {
            sizeText = next
        }
    }

    private func syncMaxWidthTextFromPanel() {
        let next = integerText(panel.maxContentWidth)
        if maxWidthText != next {
            maxWidthText = next
        }
    }

    private func applySizeTextIfValid() {
        guard let value = Double(sizeText.trimmingCharacters(in: .whitespacesAndNewlines)),
              value >= MarkdownFontSizeSettings.minimumPointSize,
              value <= MarkdownFontSizeSettings.maximumPointSize else { return }
        _ = panel.setFontSize(value)
    }

    private func applyMaxWidthTextIfValid() {
        guard let value = Double(maxWidthText.trimmingCharacters(in: .whitespacesAndNewlines)),
              value >= MarkdownMaxWidthSettings.minimumCSSPixels,
              value <= MarkdownMaxWidthSettings.maximumCSSPixels else { return }
        _ = panel.setMaxContentWidth(value)
    }

    private func commitSizeText() {
        guard let value = Double(sizeText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            syncSizeTextFromPanel()
            return
        }
        _ = panel.setFontSize(value)
        syncSizeTextFromPanel()
    }

    private func commitMaxWidthText() {
        guard let value = Double(maxWidthText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            syncMaxWidthTextFromPanel()
            return
        }
        _ = panel.setMaxContentWidth(value)
        syncMaxWidthTextFromPanel()
    }

    private func integerText(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    private var fontPicker: some View {
        // Plain system-font names: rendering each item in its own font made the
        // menu slow to open and gave rows uneven heights. The chosen font still
        // applies to the document.
        Picker(selection: fontBinding) {
            Text(String(localized: "markdown.font.system", defaultValue: "System"))
                .tag(MarkdownFontFamily.systemDefault)
            Divider()
            ForEach(pickerFamilies, id: \.self) { family in
                Text(family).tag(family)
            }
        } label: { EmptyView() }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 150, alignment: .leading)
    }
}
