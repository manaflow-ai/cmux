public import AppKit
import CmuxNextDesign
public import SwiftUI

/// The native New Tab page (Lawrence 2026-10-29: "make the new tab page in swift"): a field, the
/// Terminal | Browser | Agent switch and the dropdown under it, with no web view.
///
/// An alternative to the web page while `tabs.nativeNewTabPage` is on. Rows come from
/// ``NativeNewTabModel/rows`` as values; the view keeps no state but the field's focus.
public struct NativeNewTabView: View {
    @Bindable var model: NativeNewTabModel
    @FocusState private var fieldFocused: Bool
    private let strings = NativeNewTabStrings()

    /// Creates the view over `model`.
    public init(model: NativeNewTabModel) { self.model = model }

    /// The view in an AppKit host, for a pane tab.
    public static func hosted(_ model: NativeNewTabModel) -> NativeNewTabHostingView {
        let host = NativeNewTabHostingView(rootView: NativeNewTabView(model: model))
        host.model = model
        host.setAccessibilityIdentifier("cmux.nativeNewTab")
        return host
    }

    public var body: some View {
        VStack(spacing: Metrics.space4) {
            Spacer(minLength: 0).frame(maxHeight: 120)
            Picker("", selection: $model.kind) {
                ForEach(AgentPaneTabKind.allCases, id: \.self) { Text(strings.title($0)).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            VStack(spacing: 0) {
                field
                let rows = model.rows
                if !rows.isEmpty {
                    Divider()
                    rowList(rows)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
            .frame(maxWidth: 640)
            Spacer(minLength: 0)
        }
        .padding(Metrics.space6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { fieldFocused = true }
    }

    private var field: some View {
        HStack(spacing: Metrics.space3) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(strings.placeholder, text: $model.text)
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .font(Font(Typography.search))
                .focused($fieldFocused)
                .onSubmit { model.commit() }
                .onKeyPress(.downArrow) { model.move(1); return .handled }
                .onKeyPress(.upArrow) { model.move(-1); return .handled }
                .accessibilityIdentifier("cmux.nativeNewTab.field")
        }
        .padding(.horizontal, Metrics.space4)
        .frame(height: 44)
    }

    private func rowList(_ rows: [NativeNewTabRow]) -> some View {
        let selected = model.selectedIndex
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                NativeNewTabRowView(content: NativeNewTabRowContent(row, strings: strings), selected: index == selected) {
                    model.activate(row)
                }
            }
        }
        .padding(.vertical, Metrics.space2)
    }
}
