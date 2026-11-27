import AppKit
import CmuxNextDesign

extension SidebarView {
    func applyPresence() {
        let state = presence
        presenceButton.tintOverride = state.connected && state.active > 0 ? Palette.litGlyph : Palette.textTertiary
        presenceButton.alphaValue = state.connected ? 1 : 0.7
        let summary: String
        if state.connected {
            summary = state.working > 0
                ? "(state.active) here · (state.working) working"
                : "(state.active) here"
        } else {
            summary = "Presence unavailable"
        }
        presenceButton.themedToolTip = Strings.presenceStatus + "\n" + summary
        presenceButton.setAccessibilityValue(summary)
        presenceButton.setAccessibilityHelp(presenceButton.themedToolTip)
    }

    /// Binds the icon to the app's daemon presence refresh. The callback is intentionally
    /// owned by the app so the sidebar remains a pure view and tests can provide a fixture.
    public func bindPresence(refresh: @escaping @MainActor () async -> SidebarPresenceState) {
        Task { [weak self] in
            // concurrency-allow: this task performs one bounded daemon request per 15 seconds and has no synchronous work.
            // wakeup-allow: the refresh deadline is finite and the task is weakly owned by the sidebar.
            while !Task.isCancelled {
                let next = await refresh()
                guard let self else { return }
                if presence != next { presence = next }
                // wakeup-allow: the refresh is a bounded, user-visible presence backstop; daemon calls are event-driven.
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }
}
