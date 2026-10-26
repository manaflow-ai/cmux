#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextOracle
import Testing

/// The app's `overlays` facet (p15-oracle-038): the app list provides it, it reads the dialog center it is given,
/// focus overlays get the schema's kinds, and typed text is a real SHA-256. Run:
/// `swift test --filter OracleOverlaysAppFacetTests`.
@MainActor @Suite(.serialized) struct OracleOverlaysAppFacetTests {
    final class Host: CmuxDialogHosting {
        func show(_ dialog: CmuxDialogView, in scope: CmuxDialogScope, scopeGone: @escaping () -> Void) {}
        func hide(_ dialog: CmuxDialogView) {}
    }

    /// A visible app dialog is on the stack with no window and names its spec; the one queued behind it is not on
    /// the stack until the first is answered.
    @Test func theFacetReadsTheDialogCenter() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        #expect(services.makeOracleFacets().provided.contains(.overlays))
        let dialogs = CmuxDialogCenter(host: Host())
        let facets = OracleFacets([InputObservationBuilder.oracleOverlaysFacet(services, dialogs: dialogs, toasts: CmuxToastCenter())])

        let ok = CmuxDialogButton(id: "ok", title: "OK", role: .default)
        let first = dialogs.present(CmuxDialogSpec(title: "One", buttons: [ok], identifier: "test.first"), in: .app) { _ in }
        dialogs.present(CmuxDialogSpec(title: "Two", buttons: [ok], identifier: "test.second"), in: .app) { _ in }
        let open = try #require(try facets.beginCapture([.overlays]).completed?["overlays"])
        #expect(open["dialog"]?["specId"] == "test.first")
        #expect(Self.dialogLayers(open) == [["kind": "dialog", "window": nil]])

        #expect(dialogs.press(first, button: "ok"))
        let next = try #require(try facets.beginCapture([.overlays]).completed?["overlays"])
        #expect(next["dialog"]?["specId"] == "test.second")
        #expect(Self.dialogLayers(next) == [["kind": "dialog", "window": nil]])
    }

    @Test func focusOverlaysHaveTheSchemasKinds() {
        #expect(InputObservationBuilder.oracleKind(.palette) == .palette)
        #expect(InputObservationBuilder.oracleKind(.sheet) == .sheet)
        #expect(InputObservationBuilder.oracleKind(.groupEditor) == .popover)
        #expect(InputObservationBuilder.oracleKind(.rename) == .popover)
    }

    @Test func typedTextIsItsSHA256() {
        #expect(InputObservationBuilder.oracleSHA256("split") == "sha256:ad1a64057f9ab34fecfe3f4ee78660bb0316dbda9370581ffbeb1e8bddf3d598")
        #expect(InputObservationBuilder.oracleSHA256("error") == "sha256:ca00fccfb408989eddc401062c4d1219a6aceb6b9b55412357f1790862e8f178")
    }

    private static func dialogLayers(_ overlays: OracleValue) -> [OracleValue] {
        guard case .array(let stack)? = overlays["stack"] else { return [] }
        return stack.filter { $0["kind"] == "dialog" }
    }
}
#endif
