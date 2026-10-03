import CmuxNextDesign
import CmuxNextSettings
import Testing

struct BackdropArtSettingsTests {
    @Test func selectionAndRemovalFollowTheConfig() throws {
        #expect(try parse(#"{"appearance":{"backdropArt":"wheat-field-with-cypresses"}}"#).backdropArt == .wheatField)
        #expect(try parse(#"{"appearance":{"backdropArt":"none"}}"#).backdropArt == nil)
        #expect(try parse("{}").backdropArt == nil)
    }

    @Test(arguments: [#""vivian""#, "true", "42", "null"])
    func unknownOrNonStringArtIsRejected(_ value: String) throws {
        let snapshot = try parse(#"{"appearance":{"backdropArt":\#(value)}}"#)
        #expect(snapshot.backdropArt == nil)
        #expect(snapshot.diagnostics.contains { $0.path == "appearance.backdropArt" && $0.kind == .invalidValue })
    }

    private func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }
}
