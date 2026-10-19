import Foundation
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextTabs

/// A browser tab's sound in the tab strip and its Mute Tab action
/// (cx-d0d.24, Chrome's tab audio indicator): a speaker while the page
/// plays sound, crossed out while the tab is muted. The page's media script
/// mutes the media of the page and the frames its scripts run in
/// (`BrowserAudioMuting`).
@MainActor
enum BrowserTabAudio {
    /// What the strip shows for a page in state `state`.
    static func badge(_ state: BrowserTabState?) -> TabAudio? {
        guard let state else { return nil }
        if state.isAudioMuted { return .muted }
        return state.media?.isAudible == true ? .playing : nil
    }

    /// The tab menu reads Mute Tab or Unmute Tab for the right-clicked tab, as Chrome's
    /// Mute Site / Unmute Site row does.
    static func bindMenuTitle(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        ActionTargetTitles.set("toggleTabAudioMute", in: registry) { invocation in
            guard let id = invocation.target?.id, let (tab, _) = ctx.services.locateTab(id),
                  let state = ctx.services.cache.existingBrowser(tab.id)?.tab.state else { return nil }
            return state.isAudioMuted ? unmuteTab : muteTab
        }
    }

    static var muteTab: String { String(localized: "tabAudio.muteTab", defaultValue: "Mute Tab", table: "Handlers", bundle: .module) }
    static var unmuteTab: String { String(localized: "tabAudio.unmuteTab", defaultValue: "Unmute Tab", table: "Handlers", bundle: .module) }

    /// `toggleTabAudioMute`: mutes the tab's page, or unmutes it.
    static func toggleMute(_ ctx: AppActionContext, _ invocation: ActionInvocation) {
        guard let (tab, _) = ctx.daemonTab(invocation) else { return }
        guard let page = ctx.services.cache.existingBrowser(tab.id)?.tab as? any BrowserAudioMuting & BrowserTab else {
            return ctx.refuse(RefusalStrings.audioMuteNeedsPage)
        }
        page.setAudioMuted(!page.state.isAudioMuted)
    }
}
