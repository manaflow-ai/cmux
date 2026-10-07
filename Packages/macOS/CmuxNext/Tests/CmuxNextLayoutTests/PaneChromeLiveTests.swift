import AppKit
import CmuxNextDesign
import Observation
import Testing
@testable import CmuxNextLayout

/// Pane chrome from `DesignSettings` (cmux.json `layout.*`) applied live.
/// Part of the serialized `LayoutDesignMetricsTests` suite because it
/// mutates `DesignSettings.shared`.
extension LayoutDesignMetricsTests {
    @Test func styleTakesPaneChromeFromDesignSettings() async {
        let model = LayoutModel()
        await withPaneChrome(PaneChromeOverrides()) {
            let style = model.style
            #expect(style.panePadding == (Metrics.density == .compact ? 2 : 4))
            #expect(style.paneCornerRadius == (Metrics.density == .compact ? 6 : 8))
            #expect(style.showsPaneBorder)
        }
        await withPaneChrome(PaneChromeOverrides(padding: 5, cornerRadius: 3, border: PaneBorderStyle.none)) {
            #expect(model.style.panePadding == 5)
            #expect(model.style.paneCornerRadius == 3)
            #expect(!model.style.showsPaneBorder)
        }
        // No padding and no border: square corners unless set explicitly.
        await withPaneChrome(PaneChromeOverrides(padding: 0, border: PaneBorderStyle.none)) {
            #expect(model.style.paneCornerRadius == 0)
            #expect(!model.style.hasPaneChrome)
        }
        await withPaneChrome(PaneChromeOverrides(padding: 0, cornerRadius: 4, border: PaneBorderStyle.none)) {
            #expect(model.style.paneCornerRadius == 4)
        }
    }

    @Test func overridesAreClamped() async {
        await withPaneChrome(PaneChromeOverrides(padding: 99, cornerRadius: -3)) {
            #expect(DesignSettings.shared.paneChrome.padding == 16)
            #expect(DesignSettings.shared.paneChrome.cornerRadius == 0)
        }
    }

    @Test func styleIsObservationTrackedOnPaneChrome() async {
        let model = LayoutModel()
        nonisolated final class Flag: @unchecked Sendable { var fired = false }
        let flag = Flag()
        await withPaneChrome(PaneChromeOverrides()) {
            withObservationTracking {
                _ = model.style
            } onChange: {
                flag.fired = true
            }
            DesignSettings.shared.setPaneChrome(PaneChromeOverrides(padding: 8))
        }
        #expect(flag.fired)
    }

    @Test func rootViewAppliesPaneChromeLive() async throws {
        let splits = ScreenLayout.splits(.split("s", axis: .horizontal, ratio: 0.5, a: .leaf("a"), b: .leaf("b")))
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "", layout: splits)], activeScreenID: "s", focusedPane: "a")
        let provider = StubProvider()
        let view = LayoutRootView(model: model, contentProvider: provider)
        view.frame = CGRect(origin: .zero, size: viewport)
        view.layoutSubtreeIfNeeded()

        try await withPaneChrome(PaneChromeOverrides(padding: 4, cornerRadius: 6, border: .subtle)) {
            try await waitUntil {
                guard let host = view.context.hosts["b"] else { return false }
                return host.contentRect.minX == 4 && host.content.superview?.layer?.cornerRadius == 6
            }
            let host = try #require(view.context.hosts["b"])
            #expect(host.contentRect == host.bounds.insetBy(dx: 4, dy: 4))
            #expect(host.content.superview?.layer?.cornerRadius == 6)
            #expect(host.content.superview?.layer?.masksToBounds == true)
            // Focused pane "a": ring replaces its border; "b" shows the border.
            #expect(view.context.hosts["a"]?.chrome.showsRing == true)
            #expect(view.context.hosts["a"]?.chrome.showsBorder == false)
            #expect(host.chrome.showsBorder)
            let hidden = dividers(in: view).allSatisfy { !$0.showsIdleLine }
            #expect(hidden)

            DesignSettings.shared.setPaneChrome(PaneChromeOverrides(padding: 0, border: PaneBorderStyle.none))
            try await waitUntil {
                guard let host = view.context.hosts["b"] else { return false }
                return host.contentRect == host.bounds && host.content.superview?.layer?.cornerRadius == 0
            }
            #expect(host.content.superview?.layer?.cornerRadius == 0)
            #expect(!host.chrome.showsBorder)
            let shown = dividers(in: view).allSatisfy { $0.showsIdleLine }
            #expect(shown)
        }
        withExtendedLifetime(provider) {}
    }

    private func dividers(in view: LayoutRootView) -> [DividerHandleView] {
        let found = view.subviews.flatMap(\.subviews).compactMap { $0 as? DividerHandleView }
        #expect(!found.isEmpty)
        return found
    }
}
