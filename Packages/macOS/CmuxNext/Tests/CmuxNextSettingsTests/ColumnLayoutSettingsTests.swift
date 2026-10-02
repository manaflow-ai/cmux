import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import CoreGraphics
import Testing

/// Column and split defaults (plans/cmux-next/column-sizing.md): each
/// default is the documented value in the parser, the Settings window
/// schema and `DesignSettings`; values parse; bad values keep the default
/// with a diagnostic.
@Suite struct ColumnLayoutSettingsTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    private func schemaDefault(_ path: [String]) -> JSONValue? {
        SettingsSchema.all.first { $0.path == path }?.defaultValue
    }

    @MainActor @Test func defaultsMatchTheDocumentedValuesEverywhere() throws {
        let snapshot = try parse("{}")
        let design = DesignSettings()
        // Documented in plans/cmux-next/column-sizing.md.
        #expect(snapshot.splitSizing == .even && design.splitSizing == .even)
        #expect(snapshot.newColumnWidth == .matchCurrent && design.newColumnWidth == .matchCurrent)
        #expect(snapshot.stickyColumnEdge == .right && design.stickyColumnEdge == .right)
        #expect(snapshot.stickyColumnMode == .docked && design.stickyColumnMode == .docked)
        // Documented in plans/cmux-next/layout-model.md (decision 2).
        #expect(snapshot.frameOrientation == .columnMajor && design.frameOrientation == .columnMajor)
        #expect(snapshot.minimumPaneContentSize == CGSize(width: 200, height: 64))
        #expect(design.minimumPaneContentSize == CGSize(width: 200, height: 64))
        #expect(schemaDefault(ColumnLayoutSettings.splitSizingPath) == .string("even"))
        #expect(schemaDefault(ColumnLayoutSettings.newColumnWidthPath) == .string("matchCurrent"))
        #expect(schemaDefault(ColumnLayoutSettings.stickyEdgePath) == .string("right"))
        #expect(schemaDefault(ColumnLayoutSettings.stickyModePath) == .string("docked"))
        #expect(schemaDefault(ColumnLayoutSettings.frameOrientationPath) == .string("columnMajor"))
        #expect(schemaDefault(ColumnLayoutSettings.minimumPaneWidthPath) == .number(200))
        #expect(schemaDefault(ColumnLayoutSettings.minimumPaneHeightPath) == .number(64))
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func readsEveryValue() throws {
        let snapshot = try parse(#"{"layout": {"splitSizing": "halve", "newColumnWidth": "fitScreen", "stickyColumnEdge": "left","#
                                 + #""stickyColumnMode": "overlay", "frameOrientation": "rowMajor", "minimumPaneWidth": 320, "minimumPaneHeight": 100}}"#)
        #expect(snapshot.splitSizing == .halve)
        #expect(snapshot.newColumnWidth == .fitScreen)
        #expect(snapshot.stickyColumnEdge == .left)
        #expect(snapshot.stickyColumnMode == .overlay)
        #expect(snapshot.frameOrientation == .rowMajor)
        #expect(snapshot.minimumPaneContentSize == CGSize(width: 320, height: 100))
    }

    @Test func aNumberIsAFixedShare() throws {
        let snapshot = try parse(#"{"layout": {"newColumnWidth": 0.4, "defaultColumnWidth": 0.7}}"#)
        #expect(snapshot.newColumnWidth == .fixed)
        #expect(snapshot.defaultColumnWidth == 0.4)
    }

    @Test func badValuesKeepTheDefaultsWithDiagnostics() throws {
        let snapshot = try parse(#"{"layout": {"splitSizing": "thirds", "newColumnWidth": 5, "minimumPaneWidth": 10}}"#)
        #expect(snapshot.splitSizing == .even)
        #expect(snapshot.newColumnWidth == .matchCurrent)
        #expect(snapshot.minimumPaneContentSize.width == 200)
        #expect(Set(snapshot.diagnostics.map(\.path)) == ["layout.splitSizing", "layout.newColumnWidth", "layout.minimumPaneWidth"])
    }

    @MainActor @Test func appliesToDesignSettingsAndRevertsWhenRemoved() throws {
        let design = DesignSettings()
        let applier = SettingsApplier(design: design, registry: ActionRegistry.standard())
        applier.apply(try parse(#"{"layout": {"splitSizing": "halve", "minimumPaneHeight": 120}}"#))
        #expect(design.splitSizing == .halve)
        #expect(design.minimumPaneContentSize.height == 120)
        applier.apply(try parse("{}"))
        #expect(design.splitSizing == .even)
        #expect(design.minimumPaneContentSize.height == 64)
    }
}
