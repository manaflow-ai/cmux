package import CmuxNextBridge

/// What the page says right before it freezes or hibernates.
///
/// Keep rules (Lawrence 2026-10-24, CLAUDE.md "Copy Chrome's performance model"): a page with
/// audio, capture, the person's form input, a `beforeunload` that asks or a WebRTC connection is
/// never discarded, at any memory pressure. Chrome lets an urgent discard take a page with form
/// interaction; cmux does not.
package struct PageProbe: Hashable, Sendable {
    /// Unmuted media playing, media the tab's mute silences, or Picture in Picture.
    package var playingMedia = false
    /// The person's form edits in the tab's frames (`BrowserPageBusy.editedForm`).
    package var editedForm = false
    /// Camera, microphone or screen capture the page started (`BrowserPageBusy`).
    package var capturing = false
    /// A running Web Audio context. It may be silent (a chat app's notification sounds, a game);
    /// only the page knows whether it is heard, so it counts as audio at every pressure.
    package var webAudio = false
    /// The page would ask before it unloads (`BrowserPageBusy.beforeUnload`): it says it cannot be
    /// unloaded now, for example a half filled out form.
    package var beforeUnload = false
    /// A connected WebRTC peer connection: a discard would end the call; a freeze would stall it.
    package var webRTC = false
    /// False when the page did not answer (a script error, or no reply within the deadline):
    /// only what the tab reported on its own (`BrowserTabState.media`) is known.
    package var answered = true

    package init(playingMedia: Bool = false, editedForm: Bool = false, capturing: Bool = false, webAudio: Bool = false,
                 beforeUnload: Bool = false, webRTC: Bool = false, answered: Bool = true) {
        self.playingMedia = playingMedia
        self.editedForm = editedForm
        self.capturing = capturing
        self.webAudio = webAudio
        self.beforeUnload = beforeUnload
        self.webRTC = webRTC
        self.answered = answered
    }

    /// Why the answer keeps the page loaded, or nil when nothing it said does.
    package var exemption: HibernationPlanner.Exemption? {
        if capturing { return .capturing }
        if playingMedia { return .audio }
        if editedForm { return .formInput }
        if beforeUnload { return .beforeUnload }
        if webRTC { return .webRTC }
        return webAudio ? .webAudio : nil
    }

    /// The page does something a freeze stops (it keeps memory and state, so form input and a
    /// `beforeunload` do not count).
    package var stopsWhenFrozen: Bool { playingMedia || capturing || webAudio || webRTC }

    /// Why the probed page stays loaded now, or nil when it may hibernate.
    ///
    /// What the page said keeps it at every pressure, and so does a form result (BR-R1). A page
    /// that did not answer stays while it gets the benefit of the doubt (`PageProbeHistory`), and
    /// without memory pressure always: its form edits are unknown.
    /// - Parameters:
    ///   - pressure: The system memory pressure now.
    ///   - doubted: The page still gets the benefit of the doubt (`PageProbeHistory.doubted`).
    ///   - showsFormSubmission: The shown document came from a POST.
    package func keepReason(pressure: MemoryPressureLevel, doubted: Bool, showsFormSubmission: Bool) -> HibernationPlanner.Exemption? {
        if let exemption { return exemption }
        if showsFormSubmission { return .formSubmission }
        return !answered && (doubted || pressure == .normal) ? .unanswered : nil
    }
}
