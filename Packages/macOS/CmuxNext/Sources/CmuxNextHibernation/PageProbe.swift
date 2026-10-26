package import CmuxNextCompat
package import CmuxNextSettings

/// What the page says right before it freezes or hibernates.
///
/// Keep rules (Lawrence 2026-10-24, CLAUDE.md "Copy Chrome's performance model"): a page with
/// audio, capture, the person's form input (also in a child frame it cannot read), a `beforeunload`
/// that asks, a WebRTC connection or an open device is never discarded, at any memory pressure.
/// Chrome lets an urgent discard take a page with form interaction; cmux does not. The probe only
/// fills a candidate's lead-rule facts (``fill(_:)``); the ``DiscardRule``s decide.
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
    /// The page makes sound the person hears: unmuted media that plays, or a running Web Audio
    /// context. Not media the tab's mute silences, and not a video in Picture in Picture alone.
    /// Only an answer says so. It stamps the page's last sound for ``DiscardRule/recentlyAudible``
    /// (Chrome's `PageNode::IsAudible`, which counts what the page outputs).
    package var audible = false
    /// False when the page did not answer (a script error, or no reply within the deadline):
    /// only what the tab reported on its own (`BrowserTabState.media`) is known.
    package var answered = true

    package init(playingMedia: Bool = false, editedForm: Bool = false, capturing: Bool = false, webAudio: Bool = false,
                 beforeUnload: Bool = false, unloadHandler: Bool = false, webRTC: Bool = false, connectedDevice: Bool = false, unreadableFrame: Bool = false,
                 audible: Bool = false, answered: Bool = true) {
        self.playingMedia = playingMedia
        self.editedForm = editedForm
        self.capturing = capturing
        self.webAudio = webAudio
        self.beforeUnload = beforeUnload
        self.unloadHandler = unloadHandler
        self.webRTC = webRTC
        self.connectedDevice = connectedDevice
        self.unreadableFrame = unreadableFrame
        self.audible = audible
        self.answered = answered
    }

    /// Sets the facts the answer gives on `candidate`: what the page does now, and whether it answered.
    /// Capture the page started adds to what Page Info reports.
    ///
    /// - Parameter candidate: The page's facts, from before the probe.
    package func fill(_ candidate: inout ContentDiscardPlanner.Candidate) {
        candidate.isCapturing = candidate.isCapturing || capturing
        candidate.isAudible = playingMedia
        candidate.hasFormInput = editedForm
        candidate.hasUnreadableFrame = unreadableFrame
        candidate.asksBeforeUnload = beforeUnload
        candidate.hasWebRTC = webRTC
        candidate.hasConnectedDevice = connectedDevice
        candidate.usesWebAudio = webAudio
        candidate.isUnanswered = !answered
    }

    /// Why the answer keeps the page loaded, or nil when nothing it said does: the first rule its
    /// facts match on a page with no other facts, a missed answer not counted.
    package var exemption: HibernationPlanner.Exemption? {
        var answer = self
        answer.answered = true
        return answer.keepReason(ContentDiscardPlanner.Candidate(key: "probed", hiddenFor: 0), pressure: .critical, doubted: false)
    }

    /// The page does something a freeze stops (it keeps memory and state, so form input and a
    /// `beforeunload` do not count).
    package var stopsWhenFrozen: Bool { playingMedia || capturing || webAudio || webRTC || connectedDevice }

    /// Why the probed page stays loaded now, or nil when it may hibernate: the first registered
    /// ``DiscardRule`` that `facts`, with this answer filled in (``fill(_:)``), match.
    ///
    /// What the page said keeps it at every pressure (the lead rule), and so does a form result
    /// (BR-R1). A page that did not answer stays while it gets the benefit of the doubt
    /// (`PageProbeHistory`), and without memory pressure always: its form edits are unknown.
    /// - Parameters:
    ///   - facts: The page's facts from before the probe (`BrowserHibernation.candidate`).
    ///   - setting: `browser.hibernation`.
    ///   - pressure: The memory pressure level the hibernation acts on now.
    ///   - doubted: The page still gets the benefit of the doubt (`PageProbeHistory.doubted`).
    package func keepReason(_ facts: ContentDiscardPlanner.Candidate, setting: BrowserHibernationSetting = .fallback,
                            pressure: MemoryPressureLevel, doubted: Bool) -> HibernationPlanner.Exemption? {
        keepReason(facts, setting: setting, for: HibernationPlanner.discardReason(at: pressure), doubted: doubted)
    }

    /// Why the probed page stays loaded from a discard for `reason` (``keepReason(_:setting:pressure:doubted:)``
    /// for a discard that is not the timeout's or the pressure's, such as
    /// ``DiscardReason/frozenWithGrowingMemory``).
    package func keepReason(_ facts: ContentDiscardPlanner.Candidate, setting: BrowserHibernationSetting = .fallback,
                            for reason: DiscardReason, doubted: Bool) -> HibernationPlanner.Exemption? {
        var answer = facts
        fill(&answer)
        answer.isDoubted = doubted
        return ContentDiscardPlanner().eligibility(of: answer, setting: setting, for: reason).reason
    }
}
