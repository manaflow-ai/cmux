import AppKit
import CmuxFoundation
import SwiftUI

/// The first card in Settings > Terminal: a live preview of the terminal font
/// above the font, size, line height, and stroke rows. Each row writes one
/// Ghostty key to cmux's config and applies to open terminals right away.
struct TerminalFontCard: View {
    let hostActions: SettingsHostActions
    let model: TerminalGhosttyOptionsModel

    @State private var isPickingFamily = false
    /// The font the pointer is over in the picker: `.some(nil)` for the
    /// built-in font, `nil` when not hovering.
    @State private var hoveredFamily: String??

    var body: some View {
        SettingsCard {
            TerminalFontPreview(
                family: hoveredFamily ?? model.options.fontFamily,
                size: model.options.fontSize,
                cellHeight: model.options.cellHeight
            )
            .padding(12)
            .animation(.easeOut(duration: 0.12), value: model.options.cellHeight)
            SettingsCardDivider()
            familyRow
            SettingsCardDivider()
            sizeRow
            SettingsCardDivider()
            lineHeightRow
            SettingsCardDivider()
            thickenRow
        }
        .disabled(!model.hasLoaded)
    }

    private var familyRow: some View {
        TerminalGhosttyOptionRow(
            id: "font-family",
            title: String(localized: "settings.terminal.ghostty.fontFamily", defaultValue: "Font"),
            key: .fontFamily,
            controlWidth: 220,
            overriddenBy: model.overriddenKeys[.fontFamily]
        ) {
            Button {
                isPickingFamily.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text(verbatim: model.options.fontFamily ?? String.localizedStringWithFormat(
                        String(localized: "settings.terminal.font.builtIn", defaultValue: "Default (%@)"),
                        NSFont.ghosttyBuiltInFamily
                    ))
                    .font(Font(NSFont.terminalPreview(family: model.options.fontFamily, size: 12)))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 190)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .popover(isPresented: $isPickingFamily, arrowEdge: .trailing) {
                TerminalFontFamilyPicker(
                    families: model.fontFamilyChoices,
                    selection: model.options.fontFamily,
                    hoveredFamily: $hoveredFamily
                ) { family in
                    model.apply(.fontFamilies(model.options.fontFamiliesChoosing(family)))
                    hoveredFamily = nil
                    isPickingFamily = false
                }
            }
            .accessibilityIdentifier("SettingsTerminalGhosttyFontFamilyPicker")
        }
    }

    private var sizeRow: some View {
        TerminalGhosttyOptionRow(
            id: "font-size",
            title: String(localized: "settings.terminal.ghostty.fontSize", defaultValue: "Font Size"),
            key: .fontSize,
            controlWidth: 140,
            overriddenBy: model.overriddenKeys[.fontSize]
        ) {
            Stepper(
                value: Binding(get: { model.options.fontSize }, set: { model.apply(.fontSize($0)) }),
                in: 4...96,
                step: 0.5
            ) {
                Text(String.localizedStringWithFormat(
                    String(localized: "settings.fontSize.valuePoints", defaultValue: "%@ pt"),
                    hostActions.formattedFontSize(model.options.fontSize)
                ))
                .monospacedDigit()
            }
            .accessibilityIdentifier("SettingsTerminalGhosttyFontSizeStepper")
        }
    }

    private var lineHeightRow: some View {
        TerminalGhosttyOptionRow(
            id: "adjust-cell-height",
            title: String(localized: "settings.terminal.ghostty.lineHeight", defaultValue: "Line Height"),
            key: .adjustCellHeight,
            controlWidth: 140,
            overriddenBy: model.overriddenKeys[.adjustCellHeight]
        ) {
            Stepper(
                value: Binding(
                    get: { model.options.cellHeight.percentValue },
                    set: { model.apply(.cellHeight(.percent($0))) }
                ),
                in: -20...100,
                step: 2
            ) {
                Text(verbatim: lineHeightLabel)
                    .monospacedDigit()
            }
            .accessibilityIdentifier("SettingsTerminalGhosttyLineHeightStepper")
        }
    }

    private var thickenRow: some View {
        TerminalGhosttyOptionRow(
            id: "font-thicken",
            title: String(localized: "settings.terminal.ghostty.fontThicken", defaultValue: "Thicker Strokes"),
            key: .fontThicken,
            overriddenBy: model.overriddenKeys[.fontThicken]
        ) {
            Toggle("", isOn: Binding(get: { model.options.fontThicken }, set: { model.apply(.fontThicken($0)) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsTerminalGhosttyFontThickenToggle")
        }
    }

    /// `+8%`, `-4%`, or `+2 px` for a pixel value set in a config file.
    private var lineHeightLabel: String {
        switch model.options.cellHeight {
        case .percent(let percent):
            return String.localizedStringWithFormat(
                String(localized: "settings.terminal.ghostty.lineHeight.percent", defaultValue: "%@%%"),
                percent > 0 ? "+\(percent)" : String(percent)
            )
        case .pixels(let pixels):
            return String.localizedStringWithFormat(
                String(localized: "settings.terminal.ghostty.lineHeight.pixels", defaultValue: "%@ px"),
                pixels > 0 ? "+\(pixels)" : String(pixels)
            )
        }
    }
}
