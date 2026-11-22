import CmuxNextDesign
import CmuxNextSettings
import Testing

/// The attention ring's and run notification's defaults live twice: in the design layer's
/// `AttentionSettings()` and `StatusBehaviorSettings()` (CmuxNextDesignTokens draws with them
/// before any config loads and cannot read CmuxNextSettings), and in
/// schemas/settings/source/notifications.json, whose generated constants the Settings rows and the
/// parsers read. These must agree, or an empty cmux.json would draw what Settings does not show.
struct NotificationSourceDefaultsTests {
    @Test func theAttentionRingDrawsTheSourceDefaults() {
        let ring = AttentionSettings()
        #expect(ring.style == AttentionSettings.styleDefault)
        #expect(ring.color == nil)
        #expect(ring.terminalRing == AttentionSettings.terminalsDefault)
        #expect(ring.agentChatRing == AttentionSettings.agentChatsDefault)
        #expect(Double(ring.agentChatBlinkCount) == AttentionSettings.agentChatBlinkCountDefault)
        #expect(Double(ring.width) == AttentionSettings.widthDefault)
        #expect(Double(ring.blinkCount) == AttentionSettings.blinkCountDefault)
        #expect(ring.duration == AttentionSettings.pulseDurationDefault)
        #expect(ring.persists == AttentionSettings.persistDefault)
        #expect(ring.flashesOnRead == AttentionSettings.flashDefault)
        #expect(ring.flashesOnTyping == AttentionSettings.flashOnTypingDefault)
        #expect(ring.showsOnTab == AttentionSettings.showOnTabDefault)
        #expect(ring.showsOnSidebar == AttentionSettings.showOnSidebarDefault)
        #expect(ring.movesToTop == AttentionSettings.moveToTopDefault)
        #expect(ring.movesToTopOnAgentFinish == AttentionSettings.moveToTopOnAgentFinishDefault)
        let blinks = AttentionSettings.blinkRange
        #expect(Double(blinks.lowerBound)...Double(blinks.upperBound) == AttentionSettings.blinkCountRange)
        #expect(AttentionSettings.durationRange == AttentionSettings.pulseDurationRange)
    }

    @Test func runNotificationsUseTheSourceDefaults() {
        let behavior = StatusBehaviorSettings()
        #expect(behavior.runNotifyMinimumSeconds == StatusBehaviorSettings.runNotifyDefault)
        #expect(behavior.runNotifyWhenVisible == StatusBehaviorSettings.runNotifyWhenVisibleDefault)
    }
}
