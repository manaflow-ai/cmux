import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `appearance.tabShape`: block by default, rounded on request (the gooey look is `appearance.cornerFlush`), a bad value the default plus a diagnostic.
struct TabShapeSettingTests {
    private func parse(_ appearance: [String: JSONValue]) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(.object(["appearance": .object(appearance)]), validDensities: [], validMetrics: [])
    }

    @Test func aMissingKeyIsBlock() {
        let snapshot = parse([:])
        #expect(TabShapeSetting.effective(in: snapshot) == .block)
        #expect(TabShapeSetting.fallback == .block)
        #expect(!snapshot.diagnostics.contains { $0.path == "appearance.tabShape" })
    }

    @Test(arguments: TabShape.allCases)
    func everyShapeReads(shape: TabShape) {
        let snapshot = parse(["tabShape": .string(shape.rawValue)])
        #expect(TabShapeSetting.effective(in: snapshot) == shape)
        #expect(!snapshot.diagnostics.contains { $0.path == "appearance.tabShape" })
    }

    @Test func aBadValueIsBlockAndReported() {
        let snapshot = parse(["tabShape": .string("wobbly")])
        #expect(TabShapeSetting.effective(in: snapshot) == .block)
        #expect(snapshot.diagnostics.contains { $0.path == "appearance.tabShape" && $0.message.hasPrefix("expected one of") })
    }
}
