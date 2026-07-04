import Testing
@testable import CmuxSettings

@Suite("WorkspaceStateColorMode decode")
struct WorkspaceStateColorModeDecodeTests {
    @Test func decodesRawValues() {
        #expect(WorkspaceStateColorMode.decodeFromUserDefaults("replace") == .replace)
        #expect(WorkspaceStateColorMode.decodeFromJSON("blend") == .blend)
    }

    @Test func rejectsUnknownValues() {
        #expect(WorkspaceStateColorMode.decodeFromUserDefaults("merge") == nil)
        #expect(WorkspaceStateColorMode.decodeFromJSON(7) == nil)
    }

    @Test func encodesRawValues() {
        #expect(WorkspaceStateColorMode.replace.encodeForUserDefaults() as? String == "replace")
        #expect(WorkspaceStateColorMode.blend.encodeForJSON() as? String == "blend")
    }
}
