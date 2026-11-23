import AppKit
@testable import CmuxNextApps
import Testing

/// RFD 0009 slice 4: a finished component's `variant` and `state`, the Stat delta's tone and the
/// Chart's marks, with the same numbers webviews' sceneComponents.test.ts expects.
@MainActor @Suite struct AppSceneComponentsTests {
    @Test func finishedComponentsReadTheirStateAndVariant() {
        let row = AppSceneNode(type: .row, props: ["state": "loading", "variant": "prominent"])
        #expect(row.componentState == .loading)
        #expect(row.componentVariant == .prominent)
        let toggle = AppSceneNode(type: .toggle, props: ["state": "error", "variant": "prominent"])
        #expect(toggle.componentState == .error)
        #expect(toggle.componentVariant == .standard)
        let chart = AppSceneNode(type: .chart, props: ["state": "busy", "variant": "loud"])
        #expect(chart.componentState == nil)
        #expect(chart.componentVariant == .standard)
    }

    @Test func layoutNodesHaveNoStateOrVariant() {
        let stack = AppSceneNode(type: .vStack, props: ["state": "loading", "variant": "subtle"])
        #expect(stack.componentState == nil)
        #expect(stack.componentVariant == .standard)
    }

    @Test func statDeltaToneFollowsTheGoodTrend() {
        #expect(AppSceneStatNSView.deltaTone(trend: "up", goodTrend: nil) == "success")
        #expect(AppSceneStatNSView.deltaTone(trend: "down", goodTrend: nil) == "danger")
        #expect(AppSceneStatNSView.deltaTone(trend: "down", goodTrend: "down") == "success")
        #expect(AppSceneStatNSView.deltaTone(trend: "flat", goodTrend: nil) == "secondary")
        #expect(AppSceneStatNSView.deltaTone(trend: nil, goodTrend: "up") == "secondary")
        #expect(AppSceneStatNSView.trendMark("up") == "\u{2191}")
        #expect(AppSceneStatNSView.trendMark("flat") == nil)
    }

    @Test func lineChartMatchesTheWebGeometry() {
        let geometry = AppSceneChartNSView.geometry(values: [0, 10, 5], kind: .line, width: 100, height: 32)
        #expect(geometry == .line([CGPoint(x: 0, y: 31.25), CGPoint(x: 50, y: 0.75), CGPoint(x: 100, y: 16)]))
        let flat = AppSceneChartNSView.geometry(values: [3], kind: .line, width: 100, height: 32)
        #expect(flat == .line([CGPoint(x: 0, y: 16), CGPoint(x: 100, y: 16)]))
    }

    @Test func barChartStandsOnZero() {
        let geometry = AppSceneChartNSView.geometry(values: [1, 2], kind: .bar, width: 100, height: 32)
        #expect(geometry == .bars([CGRect(x: 5, y: 16, width: 40, height: 16), CGRect(x: 55, y: 0, width: 40, height: 32)]))
        let empty = AppSceneChartNSView.geometry(values: [], kind: .bar, width: 100, height: 32)
        #expect(empty == .bars([]))
    }
}
