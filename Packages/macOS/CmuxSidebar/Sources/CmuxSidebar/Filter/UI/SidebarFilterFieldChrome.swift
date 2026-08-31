public import SwiftUI

/// The filter field's frame: leading glyph, scope chip, match count, clear
/// button, and the rounded fill behind them.
///
/// The text input is injected rather than owned, so the same chrome hosts the
/// live `TextField` in the app and a plain `Text` anywhere the field has to be
/// drawn without being editable (the settings preview, the render gallery).
/// Keeping the chrome input-agnostic also means the surrounding layout is
/// exercised by everything that draws it, not only by the interactive path.
public struct SidebarFilterFieldChrome<Input: View>: View {
    /// Everything the chrome draws from.
    public let model: SidebarFilterFieldModel
    /// Geometry, scaled to the sidebar's font size.
    public let metrics: SidebarFilterMetrics
    /// The sidebar's accent color.
    public let accent: Color
    /// Whether to draw the focused accent ring.
    public let isFocused: Bool
    /// Invoked when the user clears the field.
    public let onCancel: () -> Void
    /// The text input to host.
    @ViewBuilder public let input: () -> Input

    /// Creates the chrome around `input`.
    ///
    /// - Parameters:
    ///   - model: The render snapshot.
    ///   - metrics: Geometry for the current font scale.
    ///   - accent: The sidebar accent color.
    ///   - isFocused: Whether to draw the focus ring.
    ///   - onCancel: Called when the clear button is pressed.
    ///   - input: The text input, editable or otherwise.
    public init(
        model: SidebarFilterFieldModel,
        metrics: SidebarFilterMetrics = SidebarFilterMetrics(),
        accent: Color,
        isFocused: Bool,
        onCancel: @escaping () -> Void,
        @ViewBuilder input: @escaping () -> Input
    ) {
        self.model = model
        self.metrics = metrics
        self.accent = accent
        self.isFocused = isFocused
        self.onCancel = onCancel
        self.input = input
    }

    public var body: some View {
        HStack(spacing: metrics.itemSpacing) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: metrics.accessoryFontSize, weight: .medium))
                .foregroundStyle(.secondary)

            if let scopeField = model.scopeField {
                scopeChip(scopeField)
            }

            input()
                .frame(maxWidth: .infinity, alignment: .leading)

            if model.showsMatchCount {
                // Zero is shown, not hidden. It is the calmest possible "no
                // matches" signal: the number the user is already watching
                // simply reaches 0, with no colour change anywhere.
                Text(verbatim: "\(model.matchCount)")
                    .font(.system(size: metrics.accessoryFontSize, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(model.isEmptyResult ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            }

            if model.hasQuery {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: metrics.accessoryFontSize))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(
                    localized: "sidebar.filter.clear",
                    defaultValue: "Clear filter"
                ))
            }
        }
        .padding(.horizontal, metrics.fieldPadding)
        .frame(height: metrics.fieldHeight)
        .background(background)
        .padding(.horizontal, metrics.horizontalInset)
    }

    private func scopeChip(_ field: SidebarFilterField) -> some View {
        Text(SidebarFilterScopeLabel.text(for: field))
            .font(.system(size: metrics.scopeFontSize, weight: .semibold))
            .foregroundStyle(accent)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(accent.opacity(0.15))
            )
            .fixedSize()
    }

    /// Focus reads as a slightly brighter fill and a soft accent ring rather
    /// than a hard outline. The sidebar is a resting surface that happens to
    /// contain a field; a system-weight focus border makes the field shout
    /// over the workspace list it belongs to.
    private var background: some View {
        RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
            .fill(Color.primary.opacity(isFocused ? 0.09 : 0.06))
            .overlay(
                RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                    .strokeBorder(accent.opacity(isFocused ? 0.3 : 0), lineWidth: 1)
            )
    }
}
