import Testing
@testable import CmuxMobileShell

/// The dev-tag isolation rule for auto-connect: a tagged dev phone must not
/// dial OTHER tags' dev Macs (each tagged build is an isolated identity — the
/// dogfood failure was a `dl2` phone attaching to other agents' running
/// instances). Verdicts are tri-state: `.unknownIdentity` lets each surface
/// pick fail-open (active Mac, so presence outages never strand offline
/// reconnect) or fail-closed (secondaries + non-active candidates, so the
/// cold-launch presence race cannot admit a wrong-tag Mac).
@Suite struct MobileSavedMacScopePolicyTests {
    private let dl2 = MobileIOSBuildScope("dl2")

    private func decision(tag: String?, bundle: String?, scope: MobileIOSBuildScope?) -> MobileSavedMacScopePolicy.Decision {
        MobileSavedMacScopePolicy.decision(macDevTag: tag, macBundleID: bundle, iosScope: scope)
    }

    @Test func unscopedPhoneConnectsToAnything() {
        #expect(decision(tag: "spin", bundle: "com.cmuxterm.app.debug.spin", scope: nil) == .allowed)
        #expect(decision(tag: nil, bundle: nil, scope: nil) == .allowed)
    }

    @Test func matchingDevTagAllowed() {
        #expect(decision(tag: "dl2", bundle: "com.cmuxterm.app.debug.dl2", scope: dl2) == .allowed)
    }

    @Test func otherDevTagRefused() {
        #expect(decision(tag: "spin", bundle: "com.cmuxterm.app.debug.spin", scope: dl2) == .refused)
    }

    @Test func devTagFromBundleAloneRefusedOnMismatch() {
        // Host that heartbeats tag "default" but runs a tagged debug bundle:
        // the bundle segment is the dev signal.
        #expect(decision(tag: "default", bundle: "com.cmuxterm.app.debug.spin", scope: dl2) == .refused)
    }

    @Test func productMacsAlwaysAllowed() {
        for bundle in ["com.cmuxterm.app", "com.cmuxterm.app.nightly", "com.cmuxterm.app.rc"] {
            #expect(decision(tag: "default", bundle: bundle, scope: dl2) == .allowed, "\(bundle)")
        }
    }

    @Test func noIdentityIsUnknownNotAllowed() {
        // No presence identity at all (offline Mac, presence not yet loaded):
        // the ambiguous verdict, so surfaces can fail closed.
        #expect(decision(tag: nil, bundle: nil, scope: dl2) == .unknownIdentity)
        #expect(decision(tag: "default", bundle: nil, scope: dl2) == .unknownIdentity)
        #expect(decision(tag: "", bundle: "", scope: dl2) == .unknownIdentity)
    }

    @Test func dottedBundleSuffixMatchesDashedTag() {
        // iOS scope from a bundle suffix is dotted ("my.tag"); the Mac
        // heartbeats the dashed reload tag ("my-tag"). Same slug ⇒ same build.
        let scope = MobileIOSBuildScope("my.tag")
        #expect(decision(tag: "my-tag", bundle: "com.cmuxterm.app.debug.my.tag", scope: scope) == .allowed)
        #expect(decision(tag: "my-tag2", bundle: nil, scope: scope) == .refused)
    }

    @Test func slugNormalizes() {
        #expect(MobileSavedMacScopePolicy.slug("My.Tag") == "my-tag")
        #expect(MobileSavedMacScopePolicy.slug("dl2") == "dl2")
        #expect(MobileSavedMacScopePolicy.slug("--a__b--") == "a-b")
    }
}
