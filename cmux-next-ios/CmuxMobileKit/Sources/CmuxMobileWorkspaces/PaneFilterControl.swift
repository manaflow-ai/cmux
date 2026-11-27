#if os(iOS)
import CmuxMobileDesign
import CmuxMobileLinkFFI
import CmuxTabsKit
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// The tab overview's pane filter (`PaneFilterSetting`): agent sessions only, or agent sessions
/// and terminals, with browsers (and simulator screens) on their own toggle. Leo, 2026-11-23:
/// "browsers ... we tuck that ... in some kinda toggle or setting filter whatever."
///
/// Three styles, drawn side by side in the gallery (`-cmux-mobile-recovery-gallery panefilter`):
/// - `menu` (A, the gallery variant): a glass circle with the system funnel glyph, with a small
///   count of the panes it hides, filled in the accent once the person changes the filter.
/// - `segmented` (B): a glass capsule under the title, Agents | Terminals | Browsers, each a toggle.
///   Always visible, but it takes a row of the grid on every visit for a choice made rarely.
/// - `chips` (C): the scope as two chips and Browsers as a third, as Mail's filter bar does. Most
///   legible, widest: it crowds the title on a compact phone.
public struct PaneFilterControl: View {
    public enum Style: String, CaseIterable, Sendable {
        case menu, segmented, chips

        var title: String {
            switch self {
            case .menu: "A · Menu beside More (shipped)"
            case .segmented: "B · Segmented row under the title"
            case .chips: "C · Filter chips"
            }
        }
    }

    @Bindable var setting: PaneFilterSetting
    var style: Style = .menu
    /// Hidden counts for the menu's footer ("2 terminals, 1 browser hidden").
    var result: PaneFilterResult?

    public init(setting: PaneFilterSetting, style: Style = .menu, result: PaneFilterResult? = nil) {
        self.setting = setting
        self.style = style
        self.result = result
    }

    private let metrics = TabsKitTheme.mobile.metrics

    public var body: some View {
        switch style {
        case .menu: menu
        case .segmented: segmented
        case .chips: chips
        }
    }

    // MARK: A

    private var menu: some View {
        Menu {
            MenuContent(setting: setting, result: result)
        } label: {
            Image(systemName: setting.isChanged ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                .font(.system(size: metrics.toolbarGlyph, weight: .medium))
                .foregroundStyle(setting.isChanged ? theme.colors.accent.color : theme.colors.label.color)
                .frame(width: metrics.overviewTopControl, height: metrics.overviewTopControl)
                .contentShape(.circle)
        }
        .glassEffect(.regular.interactive(), in: .circle)
        // A hidden pane never looks lost: how many the filter tucks away sits on the control.
        .overlay(alignment: .topTrailing) {
            if hiddenCount > 0 {
                Text("\(hiddenCount)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(theme.colors.label2.color)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 18)
                    .glassEffect(.regular, in: .capsule)
                    .offset(x: 4, y: -4)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel("Filter Tabs")
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("workspace.grid.paneFilter")
    }

    /// The filter's menu rows, shared by the gallery control and the overview's More menu.
    /// Keeping these rows separate avoids a nested menu when the filter is hosted by More.
    struct MenuContent: View {
        @Bindable var setting: PaneFilterSetting
        var result: PaneFilterResult?

        var body: some View {
            Picker(selection: $setting.scope) {
                Label("Agents", systemImage: "sparkle").tag(PaneScope.agents)
                Label("Agents and Terminals", systemImage: "apple.terminal").tag(PaneScope.agentsAndTerminals)
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            Section {
                Toggle(isOn: $setting.showsBrowsers) {
                    Label("Show Browsers", systemImage: "globe")
                }
            } footer: {
                if let hidden = hiddenLine { Text(hidden) }
            }
        }

        private var hiddenLine: String? {
            guard let result, result.filtering else { return nil }
            var parts: [String] = []
            if result.hiddenTerminals > 0 {
                parts.append(result.hiddenTerminals == 1 ? "1 terminal" : "\(result.hiddenTerminals) terminals")
            }
            if result.hiddenBrowsers > 0 {
                parts.append(result.hiddenBrowsers == 1 ? "1 browser" : "\(result.hiddenBrowsers) browsers")
            }
            return parts.joined(separator: ", ") + " hidden"
        }
    }

    // MARK: B

    private var segmented: some View {
        HStack(spacing: 2) {
            segment("Agents", on: true, enabled: false) {}
            segment("Terminals", on: setting.scope == .agentsAndTerminals, enabled: true) {
                setting.scope = setting.scope == .agents ? .agentsAndTerminals : .agents
            }
            segment("Browsers", on: setting.showsBrowsers, enabled: true) { setting.showsBrowsers.toggle() }
        }
        .padding(3)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityIdentifier("workspace.grid.paneFilter.segmented")
    }

    private func segment(_ title: String, on: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? theme.colors.label.color : theme.colors.label2.color)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(on ? theme.colors.label.color.opacity(0.12) : .clear, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.cmuxPressFillCapsule)
        .disabled(!enabled)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: C

    private var chips: some View {
        HStack(spacing: 8) {
            chip("Agents", systemImage: "sparkle", on: setting.scope == .agents) { setting.scope = .agents }
            chip("+ Terminals", systemImage: "apple.terminal", on: setting.scope == .agentsAndTerminals) {
                setting.scope = .agentsAndTerminals
            }
            chip("Browsers", systemImage: "globe", on: setting.showsBrowsers) { setting.showsBrowsers.toggle() }
        }
        .accessibilityIdentifier("workspace.grid.paneFilter.chips")
    }

    private func chip(_ title: String, systemImage: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(on ? Color.white : theme.colors.label.color)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .contentShape(.capsule)
        }
        .buttonStyle(.cmuxPressGlass)
        .glassEffect(on ? .regular.tint(theme.colors.accent.color).interactive() : .regular.interactive(), in: .capsule)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Text

    private var hiddenCount: Int {
        guard let result else { return 0 }
        return Int(result.hiddenTerminals + result.hiddenBrowsers)
    }

    private var hiddenLine: String? {
        guard let result, result.filtering else { return nil }
        var parts: [String] = []
        if result.hiddenTerminals > 0 {
            parts.append(result.hiddenTerminals == 1 ? "1 terminal" : "\(result.hiddenTerminals) terminals")
        }
        if result.hiddenBrowsers > 0 {
            parts.append(result.hiddenBrowsers == 1 ? "1 browser" : "\(result.hiddenBrowsers) browsers")
        }
        return parts.joined(separator: ", ") + " hidden"
    }

    private var accessibilityValue: String {
        let scope = setting.scope == .agents ? "Agents" : "Agents and Terminals"
        let shown = setting.showsBrowsers ? "\(scope), Browsers" : scope
        return hiddenLine.map { "\(shown). \($0)" } ?? shown
    }
}

#if DEBUG
/// The three styles over the grid's wallpaper, for the PR's screenshots
/// (`-cmux-mobile-recovery-gallery panefilter`): each in its default and a narrowed state.
public struct PaneFilterGallery: View {
    @State private var standard = PaneFilterSetting(defaults: nil)
    @State private var narrowed: PaneFilterSetting = {
        let setting = PaneFilterSetting(defaults: nil)
        setting.filter = PaneFilter(scope: .agents, showBrowsers: false)
        return setting
    }()

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ForEach(PaneFilterControl.Style.allCases, id: \.self) { style in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(style.title).font(.headline)
                        row(style, standard, caption: "Default: agents and terminals, browsers shown",
                            hidden: (0, 0))
                        row(style, narrowed, caption: "Agents only", hidden: (2, 1))
                    }
                    .accessibilityIdentifier("paneFilterGallery.\(style.rawValue)")
                }
            }
            .padding(20)
        }
        .background(LinearGradient(colors: [TabsKitTheme.mobile.colors.overviewTop, TabsKitTheme.mobile.colors.overviewBottom],
                                   startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    private func row(_ style: PaneFilterControl.Style, _ setting: PaneFilterSetting, caption: String,
                     hidden: (terminals: UInt32, browsers: UInt32)) -> some View {
        HStack(spacing: 12) {
            PaneFilterControl(setting: setting, style: style,
                              result: PaneFilterResult(shown: [0], hiddenTerminals: hidden.terminals,
                                                       hiddenBrowsers: hidden.browsers, filtering: true))
            Text(caption).font(.footnote).foregroundStyle(theme.colors.label2.color)
        }
    }
}
#endif
#endif
