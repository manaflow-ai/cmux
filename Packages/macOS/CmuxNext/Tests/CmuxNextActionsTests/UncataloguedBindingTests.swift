@testable import CmuxNextActions
import Testing

/// A bind whose id the catalog does not have (a typo, or a Swift step B that landed before the
/// app FFI re-pin carried its rows) returns false, leaves the action unbound and is noted in
/// ``ActionRegistry/uncataloguedBindings``: never a trap. #40159 asserted instead, and every
/// Debug build of feat-cmux-next stopped at launch on `cloud.team.sessions`, which the Rust
/// source had and the pinned cmux-app-ffi release did not.
@MainActor
@Suite struct UncataloguedBindingTests {
    @Test func everyBindFormNotesAMissingIDAndLeavesItUnbound() {
        let registry = ActionRegistry(catalog: [ActionDescriptor(id: "test.known", title: "Known", category: .other)])
        let known = registry.bind("test.known", handler: {})
        let results = [
            registry.bind("test.missing.handler", handler: {}),
            registry.bind("test.missing.invoke", invoke: { _ in }),
            registry.bind("test.missing.unavailable", unavailable: { nil }, invoke: { _ in }),
            registry.bindUnavailable("test.missing.placeholder", reason: "not here"),
            registry.bindEffect("test.missing.effect", effect: { _ in .done }),
            registry.bindEffect("test.missing.effectUnavailable", unavailable: { nil }, effect: { _ in .done }),
        ]
        #expect(known)
        #expect(results == [false, false, false, false, false, false])
        #expect(registry.uncataloguedBindings.map(\.rawValue) == [
            "test.missing.handler", "test.missing.invoke", "test.missing.unavailable",
            "test.missing.placeholder", "test.missing.effect", "test.missing.effectUnavailable",
        ])
        #expect(registry.action(for: "test.missing.effect") == nil)
        #expect(registry.action(for: "test.known") != nil)
    }
}
