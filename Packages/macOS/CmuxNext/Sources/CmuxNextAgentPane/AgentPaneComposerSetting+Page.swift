import CmuxNextCompat
public import CmuxNextSettings
public import CmuxNextWakeups

/// `agentPane.showContextUsage`, `agentPane.showDictation`, `agentPane.spellChecking`,
/// `agentPane.attachmentView` and `agentPane.scrollToBottomOnSend` (``AgentPaneComposerSetting``) reach the page as the `composer`
/// event, read by the page's composerSettings.ts. The same event carries the Debug Settings
/// reasoning slider toggle and visual style, `plainFooter`, Debug Settings' plain footer look
/// (``AgentPaneTunables/composerPlainFooter``), `modelMenu`, what the model chip opens
/// (``AgentPaneTunables/modelMenu``), and `harnessSwitch`, whether a started chat can switch
/// harness (``AgentPaneTunables/harnessSwitchInStartedChat``), and `escapeDoublePress`, whether Esc
/// stops a turn on a double press (``AgentPaneTunables/escapeStopDoublePress``). None of the last
/// four is a setting: each is read here, on the pane's side, each time the event is made.
extension AgentPageEvent {
    /// The composer's settings: `{showContextUsage, showDictation, spellChecking, attachmentView, scrollToBottomOnSend, reasoningSlider, reasoningSliderStyle, plainFooter, modelMenu, harnessSwitch, escapeDoublePress}`.
    public static func composer(_ setting: AgentPaneComposerSetting) -> AgentPageEvent {
        AgentPageEvent(kind: "composer", value: setting.pageValueWithLook)
    }
}

/// Pushing to a pane's page lives here, off ``AgentPaneView``, whose type is at its size limit;
/// the pane's model keeps the value a new page subscriber reads.
extension AgentPaneComposerSetting {
    /// Gives `view`'s page these settings (a change only, or every page while Debug Settings' plain
    /// footer look, model menu or harness switch changes).
    @MainActor public func push(to view: AgentPaneView) {
        guard Self.lookChanging || self != view.model.composer else { return }
        view.model.composer = self
        view.deliver([.composer(self)])
    }

    /// The page's value with the plain footer look, the model menu choice and the harness switch.
    var pageValueWithLook: JSONValue {
        var value = pageValue.objectValue ?? [:]
        value["plainFooter"] = .bool(AgentPaneTunables.composerPlainFooter.value)
        value["harnessPlacement"] = .string(AgentPaneTunables.harnessPlacement.value.rawValue)
        value["modelMenu"] = .string(AgentPaneTunables.modelMenu.value.rawValue)
        value["harnessSwitch"] = .bool(AgentPaneTunables.harnessSwitchInStartedChat.value)
        value["escapeDoublePress"] = .bool(AgentPaneTunables.escapeStopDoublePress.value)
        return .object(value)
    }

    /// Debug Settings' plain footer look, model menu and harness switch as the pages last got them,
    /// and whether a change is being pushed (``push(to:)`` then sends every page the event again).
    @MainActor private static var lookShown = Look(plainFooter: false, modelMenu: .compact, harnessPlacement: .left, harnessSwitch: false,
                                                   escapeDoublePress: true)
    @MainActor private static var lookChanging = false

    /// Follows Debug Settings' plain footer look, model menu and harness switch for the agent tabs:
    /// `push` (the tabs' push of their page settings to every view, hidden ones too, so this is a
    /// ``ServiceObservation``, not a view's) runs on each change, as one task on `mainWork`: `visible`,
    /// or `userBlocking` when the person's own toggle caused it.
    ///
    /// - Returns: The follow; the caller keeps it, and releasing it ends the follow.
    @MainActor public static func followLook(on mainWork: MainWorkScheduler, _ push: @escaping () -> Void) -> AnyObject {
        ServiceObservation(.visible, owner: "AgentPaneComposerSetting.look", on: mainWork) {
            Look(plainFooter: AgentPaneTunables.composerPlainFooter.value, modelMenu: AgentPaneTunables.modelMenu.value, harnessPlacement: AgentPaneTunables.harnessPlacement.value,
                 harnessSwitch: AgentPaneTunables.harnessSwitchInStartedChat.value,
                 escapeDoublePress: AgentPaneTunables.escapeStopDoublePress.value)
        } apply: { on in
            guard on != lookShown else { return }
            lookShown = on
            lookChanging = true
            push()
            lookChanging = false
        }
    }
}

/// The Debug Settings choices the `composer` event carries beside the settings.
nonisolated private struct Look: Equatable, Sendable {
    var plainFooter: Bool
    var modelMenu: AgentPaneModelMenuStyle
    var harnessPlacement: AgentPaneHarnessPlacement
    var harnessSwitch: Bool
    var escapeDoublePress: Bool
}

extension AgentPaneComposerSetting {
    /// `self` (read from cmux.json) with `current`'s Debug Settings toggles, which cmux.json never
    /// sets: `reasoningSlider` and `reasoningSliderStyle`. Lives here, not in CmuxNextSettings, so
    /// the settings export's source hash does not move.
    public func keepingDebugToggles(of current: AgentPaneComposerSetting) -> AgentPaneComposerSetting {
        var kept = self
        kept.reasoningSlider = current.reasoningSlider
        kept.reasoningSliderStyle = current.reasoningSliderStyle
        return kept
    }
}
