import CmuxNextSettings
import Testing
@testable import CmuxNextAgentPane

/// `agentPane.debug.topStripStyle`: the default sets no attribute, so the page draws as before; the
/// variants set `data-top-strip` on `<html>` beside the other tunables' attributes.
struct AgentPaneTopStripStyleTests {
    @Test func defaultSetsNoAttribute() {
        #expect(AgentPaneTunables.topStripStyle.descriptor.key == "agentPane.debug.topStripStyle")
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default).isEmpty)
    }

    @Test(arguments: [AgentPaneTopStripStyle.bump, .plain, .tray])
    func variantSetsItsAttribute(style: AgentPaneTopStripStyle) {
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: style) == ["top-strip": style.rawValue])
        #expect(AgentPaneTunables.attributes(foldLongThoughts: false, topStripStyle: style)
            == ["top-strip": style.rawValue, "fold-long-thoughts": "off"])
    }

    @Test func listedInDebugSettings() {
        #expect(AgentPaneTunables.all.contains { $0.key == "agentPane.debug.topStripStyle" })
    }
}

extension AgentPaneTopStripStyleTests {
    /// The Debug menu offers the four values in order, the default first and unchanged.
    @Test func offersTrayAfterTheOthers() {
        #expect(AgentPaneTopStripStyle.allCases.map(\.rawValue) == ["default", "bump", "plain", "tray"])
        #expect(AgentPaneTunables.topStripStyle.descriptor.key == "agentPane.debug.topStripStyle")
    }
}

struct AgentPaneReasoningSliderStyleTests {
    @Test func offersAccentAndMinimalWithAccentAsTheDefault() {
        #expect(AgentPaneReasoningSliderStyle.allCases.map(\.rawValue) == ["accent", "minimal"])
        #expect(AgentPaneTunables.reasoningSliderStyle.descriptor.key == "agent.reasoningSliderStyle")
        #expect(AgentPaneTunables.reasoningSliderStyle.value == .accent)
        #expect(AgentPaneTunables.all.contains { $0.key == "agent.reasoningSliderStyle" })
    }
}

struct AgentPaneModelMenuStyleTests {
    @Test func offersCompactAndFullWithCompactAsTheDefault() {
        #expect(AgentPaneModelMenuStyle.allCases.map(\.rawValue) == ["compact", "full"])
        #expect(AgentPaneTunables.modelMenu.descriptor.key == "agent.modelMenu")
        #expect(AgentPaneTunables.modelMenu.value == .compact)
        #expect(AgentPaneTunables.all.contains { $0.key == "agent.modelMenu" })
    }

    /// The choice rides the `composer` event beside the settings, read pane-side as the event is made
    /// (as `plainFooter` is), so the page opens the compact menu unless Debug Settings says `full`.
    @Test func theComposerEventCarriesTheModelMenuChoice() {
        let value = AgentPageEvent.composer(.fallback).value.objectValue
        #expect(value?["modelMenu"]?.stringValue == AgentPaneTunables.modelMenu.value.rawValue)
        #expect(value?["plainFooter"]?.boolValue == AgentPaneTunables.composerPlainFooter.value)
        #expect(value?["showContextUsage"]?.boolValue == true)
    }

    @Test func theComposerEventCarriesSendScrollPreference() {
        let value = AgentPageEvent.composer(.fallback).value.objectValue
        #expect(value?["scrollToBottomOnSend"]?.boolValue == true)
    }
}

/// Debug Settings' "Allow switching harness in a started chat": off by default, so a started
/// chat's model menu lists its own harness alone; it rides the `composer` event as `harnessSwitch`.
struct AgentPaneHarnessSwitchTunableTests {
    @Test func isOffByDefaultAndRidesTheComposerEvent() {
        #expect(AgentPaneTunables.harnessSwitchInStartedChat.descriptor.key == "agent.harnessSwitchInStartedChat")
        #expect(AgentPaneTunables.harnessSwitchInStartedChat.value == false)
        #expect(AgentPaneTunables.all.contains { $0.key == "agent.harnessSwitchInStartedChat" })
        let value = AgentPageEvent.composer(.fallback).value.objectValue
        #expect(value?["harnessSwitch"]?.boolValue == AgentPaneTunables.harnessSwitchInStartedChat.value)
    }
}

/// Debug Settings' "Esc stops a turn on a double press": on by default, so one Esc on an empty
/// composer only arms the stop; it rides the `composer` event as `escapeDoublePress`.
struct AgentPaneEscapeStopTunableTests {
    @Test func isOnByDefaultAndRidesTheComposerEvent() {
        #expect(AgentPaneTunables.escapeStopDoublePress.descriptor.key == "agent.escapeStopDoublePress")
        #expect(AgentPaneTunables.escapeStopDoublePress.defaultValue == true)
        #expect(AgentPaneTunables.all.contains { $0.key == "agent.escapeStopDoublePress" })
        let value = AgentPageEvent.composer(.fallback).value.objectValue
        #expect(value?["escapeDoublePress"]?.boolValue == AgentPaneTunables.escapeStopDoublePress.value)
    }
}
