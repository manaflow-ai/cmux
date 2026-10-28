import CoreGraphics
import CmuxNextSettings
import Testing

/// `layout.minimumPaneWidth` and `layout.minimumPaneHeight` (Lawrence 2026-10-28: "we should let panes be even
/// smaller"): 0 by default, which lets a pane shrink to one cell and fold into a bar; any value from 0 up is kept,
/// and a negative one keeps the default with a diagnostic.
struct MinimumPaneSizeSettingTests {
    static func parse(width: JSONValue? = nil, height: JSONValue? = nil) -> CmuxConfigSnapshot {
        var layout: [String: JSONValue] = [:]
        if let width { layout["minimumPaneWidth"] = width }
        if let height { layout["minimumPaneHeight"] = height }
        return CmuxConfigSnapshot.parse(.object(["layout": .object(layout)]), validDensities: [], validMetrics: [])
    }

    @Test func zeroByDefault() {
        let snapshot = Self.parse()
        #expect(snapshot.minimumPaneContentSize == .zero, "\(snapshot.minimumPaneContentSize)")
        #expect(!snapshot.diagnostics.contains { $0.path.hasPrefix("layout.minimumPane") }, "\(snapshot.diagnostics)")
    }

    @Test func zeroAndSmallValuesAreKept() {
        let zero = Self.parse(width: .number(0), height: .number(0))
        #expect(zero.minimumPaneContentSize == .zero)
        #expect(!zero.diagnostics.contains { $0.path.hasPrefix("layout.minimumPane") }, "\(zero.diagnostics)")
        let small = Self.parse(width: .number(40), height: .number(16))
        #expect(small.minimumPaneContentSize == CGSize(width: 40, height: 16))
        #expect(!small.diagnostics.contains { $0.path.hasPrefix("layout.minimumPane") }, "\(small.diagnostics)")
    }

    @Test func aNegativeValueKeepsTheDefaultAndSaysWhy() {
        let snapshot = Self.parse(width: .number(-8))
        #expect(snapshot.minimumPaneContentSize.width == 0)
        #expect(snapshot.diagnostics.contains { $0.path == "layout.minimumPaneWidth" }, "\(snapshot.diagnostics)")
    }

    @Test func settingsOffersZero() throws {
        for path in [["layout", "minimumPaneWidth"], ["layout", "minimumPaneHeight"]] {
            let descriptor = try #require(SettingsSchema.descriptor(for: path))
            #expect(descriptor.defaultValue == .number(0), "\(path)")
            guard case let .number(number) = descriptor.kind else {
                Issue.record("\(path) is not a number row")
                continue
            }
            #expect(number.range.lowerBound == 0, "\(path): \(number.range)")
        }
    }
}
