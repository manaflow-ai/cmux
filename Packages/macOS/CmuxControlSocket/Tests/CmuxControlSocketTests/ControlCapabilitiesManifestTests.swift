import Testing
@testable import CmuxControlSocket

@Suite("ControlCapabilitiesManifest")
struct ControlCapabilitiesManifestTests {
    private let manifest = ControlCapabilitiesManifest.frozen

    /// The advertised set (what `system.capabilities` emits after sorting) must
    /// have no duplicate method names; a duplicate would have changed the
    /// `methods` array length without changing the sorted output, masking a
    /// copy-paste error in the catalog.
    @Test func releaseMethodsHaveNoDuplicates() {
        #expect(Set(manifest.releaseMethods).count == manifest.releaseMethods.count)
    }

    @Test func debugMethodsHaveNoDuplicates() {
        #expect(Set(manifest.debugMethods).count == manifest.debugMethods.count)
    }

    /// The release and DEBUG sets are disjoint: the DEBUG build advertises the
    /// union, so any overlap would duplicate a method in the sorted output.
    @Test func releaseAndDebugSetsAreDisjoint() {
        #expect(Set(manifest.releaseMethods).isDisjoint(with: Set(manifest.debugMethods)))
    }

    /// The four `system.*` control methods are always advertised.
    @Test func advertisesSystemMethods() {
        #expect(Set(manifest.releaseMethods).isSuperset(of: [
            "system.ping",
            "system.capabilities",
            "system.top",
            "system.memory",
        ]))
    }

    /// Every DEBUG-only advertised method is `debug.`-scoped (or the lone
    /// `mobile.dev_stack_auth.configure` dev hook), so a release build never
    /// leaks a debug capability into the advertised surface.
    @Test func debugAdvertisedMethodsAreDebugScoped() {
        for method in manifest.debugMethods {
            #expect(
                method.hasPrefix("debug.") || method == "mobile.dev_stack_auth.configure",
                "unexpected DEBUG-only capability \(method)"
            )
        }
    }
}
