import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextPalette
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-11-03 (Cmd-Shift-P): "'toggle' options are very confusing, since we don't know the
/// current state". Every on/off appearance and settings toggle row says whether its setting is on now,
/// follows the setting when it changes elsewhere, and flips when the row runs.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SettingsTogglePaletteStateTests {
    struct Fixture {
        let services: AppServices
        let design: DesignSettings
        let tunables: TunableStore
        var registry: ActionRegistry { services.registry }
    }

    /// The app's actions, with the appearance and focus ring ones on `design` and the Debug
    /// choices on a store of their own.
    static func fixture(design: DesignSettings) -> Fixture {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        var context = AppActionContext(services: services)
        context.design = design
        let tunables = TunableStore()
        tunables.register([GlassLensMode.tunable.descriptor])
        tunables.activate(file: nil)
        AppearanceHandlers.bind(into: services.registry, context: context, tunables: tunables)
        FocusRingHandlers.bind(into: services.registry, context: context)
        return Fixture(services: services, design: design, tunables: tunables)
    }

    /// One on/off palette toggle and how to turn its setting on or off without running it.
    enum Toggle: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case newTabAnimations, newWorkspaceAnimations, allAnimations
        case sidebarAnimations, tabAnimations, paneAnimations, overlayAnimations, hoverCardAnimations
        case homeAnimations, cursorAnimations, indicatorAnimations, feedbackAnimations, webAnimations
        case paneBorders, panePadding, paneCorners, focusRing, singlePaneFocusRing, thickPaneBorders
        case glassLens, actionLatencyHUD

        var testDescription: String { rawValue }

        var id: ActionID {
            switch self {
            case .newTabAnimations: "appearance.animations.newTab.toggle"
            case .newWorkspaceAnimations: "appearance.animations.newWorkspace.toggle"
            case .allAnimations: "appearance.animations.toggle"
            case .sidebarAnimations: "appearance.animations.sidebar.toggle"
            case .tabAnimations: "appearance.animations.tabs.toggle"
            case .paneAnimations: "appearance.animations.panes.toggle"
            case .overlayAnimations: "appearance.animations.overlays.toggle"
            case .hoverCardAnimations: "appearance.animations.hoverCards.toggle"
            case .homeAnimations: "appearance.animations.home.toggle"
            case .cursorAnimations: "appearance.animations.cursor.toggle"
            case .indicatorAnimations: "appearance.animations.indicators.toggle"
            case .feedbackAnimations: "appearance.animations.feedback.toggle"
            case .webAnimations: "appearance.animations.web.toggle"
            case .paneBorders: "appearance.paneBorder.toggle"
            case .panePadding: "appearance.panePadding.toggle"
            case .paneCorners: "appearance.paneCorners.toggle"
            case .focusRing: "focusRing.toggle"
            case .singlePaneFocusRing: "focusRing.singlePane.toggle"
            case .thickPaneBorders: "appearance.paneBorderWidth.toggle"
            case .glassLens: "appearance.glass.lens.toggle"
            case .actionLatencyHUD: "debug.actionLatencyHUD"
            }
        }

        /// The drawn padding and corner radius come from `Metrics`, which reads the app-wide design.
        var readsMetrics: Bool { self == .panePadding || self == .paneCorners }

        private var category: MotionCategory? {
            switch self {
            case .sidebarAnimations: .sidebar
            case .tabAnimations: .tabs
            case .paneAnimations: .panes
            case .overlayAnimations: .overlays
            case .hoverCardAnimations: .hoverCards
            case .homeAnimations: .home
            case .cursorAnimations: .cursor
            case .indicatorAnimations: .indicators
            case .feedbackAnimations: .feedback
            case .webAnimations: .web
            default: nil
            }
        }

        /// Turns the setting on or off the way the settings file or Settings window would.
        func set(_ on: Bool, _ f: Fixture) {
            let design = f.design
            var chrome = design.paneChrome
            if let category {
                if on { design.disabledAnimationCategories.remove(category) } else { design.disabledAnimationCategories.insert(category) }
                return
            }
            switch self {
            case .newTabAnimations, .newWorkspaceAnimations:
                let kind: MotionKind = self == .newTabAnimations ? .newTab : .newWorkspace
                if on { design.enabledAnimations.insert(kind) } else { design.enabledAnimations.remove(kind) }
            case .allAnimations: design.animationsEnabled = on
            case .paneBorders: chrome.border = on ? .subtle : PaneBorderStyle.none; design.setPaneChrome(chrome)
            case .panePadding: chrome.padding = on ? 6 : 0; design.setPaneChrome(chrome)
            case .paneCorners: chrome.cornerRadius = on ? 6 : 0; design.setPaneChrome(chrome)
            case .thickPaneBorders: chrome.borderWidth = on ? 2 : nil; design.setPaneChrome(chrome)
            case .focusRing: design.focusRing.enabled = on
            case .singlePaneFocusRing: design.focusRing.showsForSinglePane = on
            case .glassLens: GlassLensMode.choose(on ? .lens : .plain, in: f.tunables)
            case .actionLatencyHUD: on ? f.services.actionLatencyHUD.show(over: nil) : f.services.actionLatencyHUD.hide()
            default: Issue.record("\(self) has no setter")
            }
        }
    }

    /// What `id`'s palette row says: on, off, or nil when it says nothing.
    private func rowState(_ id: ActionID, _ f: Fixture) -> Bool? {
        let rows = RegistryPaletteProvider(registry: f.registry).makeItems()
        #expect(rows.contains { $0.id == "action:\(id.rawValue)" }, "\(id) has no palette row")
        return f.registry.action(for: id)?.paletteState?()
    }

    @Test(arguments: Toggle.allCases)
    func theRowSaysWhetherTheSettingIsOnNow(_ toggle: Toggle) throws {
        let design = toggle.readsMetrics ? DesignSettings.shared : DesignSettings()
        let saved = design.paneChrome
        defer { design.setPaneChrome(saved) }
        let f = Self.fixture(design: design)
        defer { f.services.actionLatencyHUD.close() }
        for on in [true, false, true] {
            toggle.set(on, f)
            #expect(rowState(toggle.id, f) == on, "\(toggle): the setting is \(on ? "on" : "off")")
        }
        toggle.set(false, f)
        #expect(f.registry.perform(toggle.id))
        #expect(rowState(toggle.id, f) == true, "\(toggle): running the off row did not show it on")
        #expect(f.registry.perform(toggle.id))
        #expect(rowState(toggle.id, f) == false, "\(toggle): running the on row did not show it off")
    }
}
