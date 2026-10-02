import Foundation
import Testing
@testable import CmuxNextDesign

/// Search, exports, and the shipped Design tunables (unique keys, defaults
/// inside their ranges, code defaults unchanged).
@MainActor
@Suite struct TunableCatalogTests {
    static let section = TunableSection(id: "test", title: "Testing", symbol: "testtube.2", order: 99)
    let gap = Tunable<Double>.number("drop.overlay.splitPreview.gap", section, "Split preview: gap", help: "Gap between panes.",
                                     default: 6, range: 0...30, step: 0.5, unit: .points, code: "DropOverlayTunables.splitGap")
    let style = Tunable<TestSpeed>.choice("motion.speed", section, "Animation speed", help: "Café pacing.", default: .fast)

    @Test func searchMatchesLabelKeyHelpAndSectionIgnoringCaseAndAccents() {
        let rows = [gap.descriptor, style.descriptor]
        #expect(TunableSearch.filter(rows, query: "GAP").map(\.key) == ["drop.overlay.splitPreview.gap"])
        #expect(TunableSearch.filter(rows, query: "splitpreview").count == 1)
        #expect(TunableSearch.filter(rows, query: "cafe").map(\.key) == ["motion.speed"])
        #expect(TunableSearch.filter(rows, query: "testing").count == 2)
        #expect(TunableSearch.filter(rows, query: "split speed").isEmpty)
        #expect(TunableSearch.filter(rows, query: "  ").count == 2)
    }

    @Test func exportsOnlyValuesThatDifferFromTheirDefaults() {
        let changes = TunableExport.changes(descriptors: [gap.descriptor, style.descriptor],
                                            overrides: [gap.key: .number(8.5), style.key: .choice("fast")])
        #expect(changes.map(\.descriptor.key) == [gap.key])
        let json = TunableExport.json(changes)
        #expect(json.contains("\"drop.overlay.splitPreview.gap\" : 8.5"))
        let swift = TunableExport.swiftDefaults(changes)
        #expect(swift.contains("DropOverlayTunables.splitGap: 8.5"))
        #expect(swift.contains("was 6"))
        #expect(TunableExport.swiftDefaults([]).hasPrefix("//"))
    }

    @Test func swiftLiteralsAreValidSwift() {
        #expect(TunableExport.swiftLiteral(.number(0.2500)) == "0.25")
        #expect(TunableExport.swiftLiteral(.number(28)) == "28")
        #expect(TunableExport.swiftLiteral(.choice("insetCard")) == ".insetCard")
        #expect(TunableExport.swiftLiteral(.spring(SpringParameters(response: 0.2, dampingFraction: 0.9)))
            == "SpringParameters(response: 0.2, dampingFraction: 0.9)")
    }

    @Test func shippedTunablesHaveUniqueKeysAndDefaultsInRange() {
        let all = DesignTunables.all
        #expect(Set(all.map(\.key)).count == all.count)
        for descriptor in all {
            let value = descriptor.defaultValue
            #expect(descriptor.clamp(value) == value, "\(descriptor.key) default \(value) is outside its range")
            #expect(!descriptor.label.isEmpty && !descriptor.help.isEmpty, "\(descriptor.key) needs a label and help")
        }
    }

    @Test func codeDefaultsAreUnchanged() {
        // The shared store is inert in tests: these are the code defaults.
        #expect(MotionSpring.move.base == SpringParameters(response: 0.2, dampingFraction: 0.9))
        #expect(MotionSpring.track.base == SpringParameters(response: 0.12, dampingFraction: 0.9))
        #expect(MotionSpring.settle.base == SpringParameters(response: 0.22, dampingFraction: 0.85))
        #expect(MotionFade.hover.baseDuration == 0.08)
        #expect(MotionFade.theme.baseDuration == 0.16)
        #expect(MotionLoop.pulse.period == 1.8)
        #expect(MotionMarquee.delay == 0.6)
        #expect(Motion.panelOpenScale == 0.97)
        #expect(Metrics.space1 == 2 && Metrics.space6 == 16)
        #expect(Metrics.dividerHitWidth == 7)
        #expect(Metrics.tabBackgroundInset == 1)
        #expect(Metrics.trafficLightInset == 76)
        if Metrics.density == .compact {
            #expect(Metrics.tabStripHeight == 28)
            #expect(Metrics.sidebarWidth == 208)
            #expect(Metrics.panelCornerRadius == 10)
        }
    }

    @Test func derivedDefaultsFollowDensity() {
        let descriptor = MetricTunables.tabHeight.descriptor
        #expect(descriptor.defaultValue == .number(Double(Metrics.tabHeight)))
        #expect(descriptor.help.contains("24 compact, 30 comfortable"))
    }
}
