import AppKit
@testable import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// The launch binds in two steps (startup-under-100ms): `AppActions.bind(deferring: true)` before the
/// first frame, `AppActions.bindDeferred` after it. Once both ran, the registry holds what one
/// synchronous `AppActions.bind` gives: the same bound ids, each with the same rules, and no id bound
/// twice. A deferred binder whose action a pre-frame binder or rule amends, or that a catalog request
/// row took, fails here.
@MainActor
struct DeferredBindersTests {
    /// Which of an action's optional parts are set: a rule that ran on an unbound id leaves its part nil.
    private static func shape(_ action: Action) -> [Bool] {
        [action.argumentHandler != nil, action.invoke != nil, action.effect != nil, action.unavailableReason != nil,
         action.targetUnavailableReason != nil, action.targetTitle != nil, action.targetState != nil,
         action.paletteState != nil, action.paletteStateIsSetting, action.paletteUnavailableReason != nil,
         action.choiceState != nil, action.paletteTitle != nil, action.targetHidden != nil, action.menuHidden != nil]
    }

    @Test func theLaunchsTwoStepsBindWhatOneBindDoes() {
        _ = NSApplication.shared
        let whole = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(whole)
        let split = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(split, deferring: true)
        let beforeFrame = Set(split.registry.actions.map(\.id))
        AppActions.bindDeferred(split)

        #expect(split.registry.duplicateBindings.isEmpty, "bound twice: \(split.registry.duplicateBindings.map(\.rawValue))")
        let wholeIDs = Set(whole.registry.actions.map(\.id)), splitIDs = Set(split.registry.actions.map(\.id))
        #expect(wholeIDs == splitIDs, "only in one bind: \(wholeIDs.symmetricDifference(splitIDs).map(\.rawValue).sorted())")
        #expect(splitIDs.count > beforeFrame.count, "the deferred binders bound nothing")
        let differ = whole.registry.actions.filter { action in
            split.registry.action(for: action.id).map { Self.shape($0) != Self.shape(action) } ?? false
        }
        #expect(differ.isEmpty, "rules lost when deferred: \(differ.map(\.id.rawValue).sorted())")
    }
}
