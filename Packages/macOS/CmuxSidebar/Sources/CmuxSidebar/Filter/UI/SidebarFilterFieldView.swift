public import SwiftUI

/// The sidebar's live filter field: ``SidebarFilterFieldChrome`` hosting an
/// editable text field.
///
/// Renders from a value snapshot plus an action bundle, never from a store, so
/// it satisfies the same snapshot-boundary rule as the rows below it.
public struct SidebarFilterFieldView: View {
    /// Everything the field draws from.
    public let model: SidebarFilterFieldModel
    /// Geometry, scaled to the sidebar's font size.
    public let metrics: SidebarFilterMetrics
    /// The sidebar's accent color.
    public let accent: Color
    /// Live binding for the text field's contents.
    @Binding public var queryText: String
    /// Invoked when the user clears the field or presses Escape.
    public let onCancel: () -> Void

    @FocusState private var isFocused: Bool

    /// Creates a filter field.
    ///
    /// - Parameters:
    ///   - model: The render snapshot.
    ///   - metrics: Geometry for the current font scale.
    ///   - accent: The sidebar accent color.
    ///   - queryText: Binding to the field's text.
    ///   - onCancel: Called on clear or Escape.
    public init(
        model: SidebarFilterFieldModel,
        metrics: SidebarFilterMetrics = SidebarFilterMetrics(),
        accent: Color,
        queryText: Binding<String>,
        onCancel: @escaping () -> Void
    ) {
        self.model = model
        self.metrics = metrics
        self.accent = accent
        self._queryText = queryText
        self.onCancel = onCancel
    }

    public var body: some View {
        SidebarFilterFieldChrome(
            model: model,
            metrics: metrics,
            accent: accent,
            isFocused: isFocused,
            onCancel: onCancel
        ) {
            TextField(
                String(localized: "sidebar.filter.placeholder", defaultValue: "Filter workspaces"),
                text: $queryText
            )
            .textFieldStyle(.plain)
            .font(.system(size: metrics.queryFontSize))
            .focused($isFocused)
            .onExitCommand(perform: onCancel)
        }
        .accessibilityIdentifier("SidebarFilterField")
    }
}
