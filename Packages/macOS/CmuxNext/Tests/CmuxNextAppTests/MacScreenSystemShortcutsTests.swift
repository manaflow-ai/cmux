import CmuxNextRemoteView
import Testing

/// "Send System Shortcuts to the Remote Mac": the helper's session event tap takes keys only
/// while every condition holds. Which chords it takes is tested with the tap itself, in
/// cmux-rd-host `src/shortcut_tap.rs`.
struct MacScreenSystemShortcutTapTests {
    private let policy = RemoteSystemShortcuts()
    private let all = RemoteSystemShortcuts.Conditions(setting: true, accessibility: true, hasKeyboard: true, live: true,
                                                       windowKey: true, appActive: true)

    @Test func installsOnlyWhileEveryConditionHolds() {
        #expect(policy.installs(all))
        let each: [WritableKeyPath<RemoteSystemShortcuts.Conditions, Bool>] = [
            \.setting, \.accessibility, \.hasKeyboard, \.live, \.windowKey, \.appActive,
        ]
        for path in each {
            var conditions = all
            conditions[keyPath: path] = false
            #expect(!policy.installs(conditions))
        }
        #expect(!policy.installs(RemoteSystemShortcuts.Conditions()))
    }
}
