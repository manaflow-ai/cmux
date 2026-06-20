import Testing
@testable import CmuxControlSocket

@Suite("ControlSocketCommandPolicy")
struct ControlSocketCommandPolicyTests {
    let policy = ControlSocketCommandPolicy.standard

    @Test func v2FocusIntentMethodsAllowFocusWithoutAnExplicitParam() {
        #expect(policy.allowsInAppFocusMutations(commandKey: "workspace.select", isV2: true))
        #expect(policy.allowsInAppFocusMutations(commandKey: "window.focus", isV2: true))
        #expect(policy.allowsInAppFocusMutations(commandKey: "feed.jump", isV2: true))
    }

    @Test func v2ExplicitFocusParamMethodsRequireTheParam() {
        // `surface.create` honors `focus`, so the resolved param drives it.
        #expect(!policy.allowsInAppFocusMutations(commandKey: "surface.create", isV2: true, explicitFocusParam: false))
        #expect(policy.allowsInAppFocusMutations(commandKey: "surface.create", isV2: true, explicitFocusParam: true))
        // pane.join is shared by surface.move via the same table.
        #expect(policy.allowsInAppFocusMutations(commandKey: "pane.join", isV2: true, explicitFocusParam: true))
    }

    @Test func v2NonFocusMethodsNeverAllowFocus() {
        #expect(!policy.allowsInAppFocusMutations(commandKey: "surface.trigger_flash", isV2: true, explicitFocusParam: true))
        #expect(!policy.allowsInAppFocusMutations(commandKey: "settings.open", isV2: true, explicitFocusParam: true))
        #expect(!policy.allowsInAppFocusMutations(commandKey: "debug.type", isV2: true, explicitFocusParam: true))
    }

    @Test func v1FocusIntentCommands() {
        #expect(policy.allowsInAppFocusMutations(commandKey: "focus_window", isV2: false))
        #expect(policy.allowsInAppFocusMutations(commandKey: "activate_app", isV2: false))
        #expect(!policy.allowsInAppFocusMutations(commandKey: "ping", isV2: false))
        #expect(!policy.allowsInAppFocusMutations(commandKey: "simulate_shortcut", isV2: false))
    }

    @Test func v1RightSidebarDefersToTheCallerSuppliedDecision() {
        #expect(policy.allowsInAppFocusMutations(commandKey: "right_sidebar", isV2: false, rightSidebarAllowsFocus: true))
        #expect(!policy.allowsInAppFocusMutations(commandKey: "right_sidebar", isV2: false, rightSidebarAllowsFocus: false))
    }
}

@Suite("ControlSocketFocusAllowanceStack")
struct ControlSocketFocusAllowanceStackTests {
    @Test func emptyStackSuppressesActivationAndDeniesFocus() {
        let stack = ControlSocketFocusAllowanceStack()
        #expect(!stack.isCommandActive)
        #expect(!stack.topAllowsFocusMutation)
    }

    @Test func withPolicyPushesAndPopsTheAllowance() {
        let stack = ControlSocketFocusAllowanceStack()
        stack.withPolicy(allowsInAppFocusMutations: true) {
            #expect(stack.isCommandActive)
            #expect(stack.topAllowsFocusMutation)
        }
        #expect(!stack.isCommandActive)
        #expect(!stack.topAllowsFocusMutation)
    }

    @Test func nestedFramesReadTheInnermostAllowance() {
        let stack = ControlSocketFocusAllowanceStack()
        stack.withPolicy(allowsInAppFocusMutations: true) {
            #expect(stack.topAllowsFocusMutation)
            stack.withPolicy(allowsInAppFocusMutations: false) {
                #expect(stack.isCommandActive)
                #expect(!stack.topAllowsFocusMutation)
            }
            #expect(stack.topAllowsFocusMutation)
        }
    }

    @Test func withStackReinstatesACapturedStackForTheMainHop() {
        let stack = ControlSocketFocusAllowanceStack()
        // Empty here; simulate the captured worker-thread stack being replayed.
        stack.withStack([true]) {
            #expect(stack.isCommandActive)
            #expect(stack.topAllowsFocusMutation)
        }
        #expect(!stack.isCommandActive)
    }

    @Test func twoInstancesDoNotAlias() {
        let a = ControlSocketFocusAllowanceStack()
        let b = ControlSocketFocusAllowanceStack()
        a.withPolicy(allowsInAppFocusMutations: true) {
            #expect(a.isCommandActive)
            #expect(!b.isCommandActive)
        }
    }
}
