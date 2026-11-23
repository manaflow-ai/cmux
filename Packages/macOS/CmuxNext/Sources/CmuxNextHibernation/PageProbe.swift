package import CmuxNextBrowserCore
package import CmuxNextCompat

/// What the page says right before it freezes or hibernates.
///
/// Keep rules (Lawrence 2026-10-24, CLAUDE.md "Copy Chrome's performance model"): a page with
/// audio, capture, the person's form input (also in a child frame it cannot read), a `beforeunload`
/// that asks, a WebRTC connection or an open device is never discarded, at any memory pressure. Chrome lets an urgent discard take a page with form
/// interaction; cmux does not.
package struct PageProbe: Hashable, Sendable {
    /// What the tab's own media state says plays: its speaker (sound outside the document too, issue
    /// 38062), media its mute silences (cx-d0d.24), or a video in Picture in Picture, which plays on in its
    /// floating window, paused or muted alike.
    package static func tabPlays(_ media: BrowserMediaState?, muted: Bool) -> Bool {
        media.map { $0.isSounding || ($0.isPlaying && muted) || $0.isPictureInPicture } ?? false
    }

    /// A page that did not answer. It used to count as playing, so a page too busy to answer
    /// never froze and was asked again every `freezeSeconds` (the hottest renderer in the
    /// 2026-10-21 audit: 25 % CPU, 586 MB). The media the tab last reported still keeps it: the
    /// page's media script pushes that state (`BrowserMediaState+Scripts`), with no round trip.
    /// WebKit's own camera and microphone state is the planner's `isCapturing`; Chromium reports none to the app.
    package static func unanswered(media: BrowserMediaState?, muted: Bool) -> PageProbe {
        PageProbe(playingMedia: tabPlays(media, muted: muted), mediaSession: resumable(media), answered: false)
    }

    /// The tab's media the person resumes from outside the page (``mediaSession``): an element that is not
    /// muted, or one whose page handles `mediaSession` actions. A muted autoplay or ad video, or sound with no
    /// element, is no session: such a page still freezes.
    package static func resumable(_ media: BrowserMediaState?) -> Bool {
        media.map { !$0.isSoundOnly && (!$0.isMuted || !$0.actions.isEmpty) } ?? false
    }

    /// Unmuted media playing, media the tab's mute silences, or Picture in Picture.
    package var playingMedia = false
    /// The tab reports media it can resume (``resumable(_:)``), paused too: the person resumes it from
    /// macOS Now Playing, the media keys or the tab's media menu, and each of those runs in the page. A frozen
    /// page runs none of them, so Play did nothing (https://github.com/manaflow-ai/cmux/issues/51079: a
    /// paused open.spotify.com tab froze 30 s after it was hidden, and its music never came back). It keeps
    /// the page from a freeze only; a discard ends the session with the page.
    package var mediaSession = false
    /// The person's form edits in the tab's frames (`BrowserPageBusy.editedForm`).
    package var editedForm = false
    /// Camera, microphone or screen capture the page started (`BrowserPageBusy`).
    package var capturing = false
    /// A running Web Audio context. It may be silent (a chat app's notification sounds, a game);
    /// only the page knows whether it is heard, so it counts as audio at every pressure.
    package var webAudio = false
    /// The page would ask before it unloads (a child frame's `BrowserPageBusy.beforeUnload`): it says
    /// it cannot be unloaded now, for example a half filled out form.
    package var beforeUnload = false
    /// The person used the top document and it has a `beforeunload` handler
    /// (`BrowserPageBusy.unloadHandler`): it may ask. Not a keep reason by itself; the hibernation
    /// runs the handlers only right before the discard, once nothing else keeps the page.
    package var unloadHandler = false
    /// A connected WebRTC peer connection: a discard would end the call; a freeze would stall it.
    package var webRTC = false
    /// An open USB, HID or serial device, or a connected Bluetooth GATT server (Chrome's
    /// kConnectedToUSB and kConnectedToBluetooth): a discard drops the connection.
    package var connectedDevice = false
    /// The person moved into a child frame whose fields cannot be read (Chromium's cross-origin
    /// frames have no recorder): its edits are unknown, so they count as the person's input.
    package var unreadableFrame = false
    /// False when the page did not answer (a script error, or no reply within the deadline):
    /// only what the tab reported on its own (`BrowserTabState.media`) is known.
    package var answered = true

    package init(playingMedia: Bool = false, mediaSession: Bool = false, editedForm: Bool = false, capturing: Bool = false, webAudio: Bool = false,
                 beforeUnload: Bool = false, unloadHandler: Bool = false, webRTC: Bool = false, connectedDevice: Bool = false, unreadableFrame: Bool = false,
                 answered: Bool = true) {
        self.playingMedia = playingMedia
        self.mediaSession = mediaSession
        self.editedForm = editedForm
        self.capturing = capturing
        self.webAudio = webAudio
        self.beforeUnload = beforeUnload
        self.unloadHandler = unloadHandler
        self.webRTC = webRTC
        self.connectedDevice = connectedDevice
        self.unreadableFrame = unreadableFrame
        self.answered = answered
    }

    /// Why the answer keeps the page loaded, or nil when nothing it said does.
    package var exemption: HibernationPlanner.Exemption? {
        if capturing { return .capturing }
        if playingMedia { return .audio }
        if editedForm { return .formInput }
        if unreadableFrame { return .unreadableFrame }
        if beforeUnload { return .beforeUnload }
        if webRTC { return .webRTC }
        if connectedDevice { return .connectedDevice }
        return webAudio ? .webAudio : nil
    }

    /// The page does something a freeze stops (it keeps memory and state, so form input and a
    /// `beforeunload` do not count), or holds a media session the person resumes from outside it.
    package var stopsWhenFrozen: Bool { playingMedia || mediaSession || capturing || webAudio || webRTC || connectedDevice }

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
