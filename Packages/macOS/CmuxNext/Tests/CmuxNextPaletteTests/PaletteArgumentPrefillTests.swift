import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// A prompt for a target's new name or description starts from the current one, and Return on
/// that untouched text closes without running (the text is a snapshot that may be stale). Other
/// text arguments start empty.
@MainActor
@Suite
struct PaletteArgumentPrefillTests {
    private final class Targets: PaletteTargetSource {
        func targets(of kind: ActionTargetKind) -> [PaletteTargetOption] {
            kind == .workspace ? [PaletteTargetOption(id: "ws_1", title: "release")] : []
        }

        func currentDescription(of target: ActionTargetRef) -> String? {
            target.kind == .workspace && target.id == "ws_1" ? "Ship the release" : nil
        }
    }

    private static func textSpec(_ id: ActionID) throws -> PaletteTextInputSpec {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == id })
        let flow = PaletteArgumentFlow(registry: ActionRegistry.standard(), descriptor: descriptor, targets: Targets())
        let effect = flow.effect(collected: ActionInvocation(target: ActionTargetRef(kind: .workspace, id: "ws_1")))
        var spec: PaletteTextInputSpec?
        if case .textInput(let input) = effect { spec = input }
        return try #require(spec, "\(id) does not ask for text")
    }

    @Test func editWorkspaceDescriptionStartsFromTheCurrentDescription() throws {
        let spec = try Self.textSpec("editWorkspaceDescription")
        #expect(spec.initialText == "Ship the release")
        #expect(spec.skipsUnchangedText)
    }

    @Test func renameWorkspaceStillStartsFromTheCurrentName() throws {
        let spec = try Self.textSpec("renameWorkspace")
        #expect(spec.initialText == "release")
        #expect(spec.skipsUnchangedText)
    }
}
