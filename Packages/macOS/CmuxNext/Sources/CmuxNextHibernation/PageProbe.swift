package import CmuxNextCompat

/// What the page says right before it freezes or hibernates: facts only. What they keep (audio,
/// capture, the person's form input, a `beforeunload` that asks, a WebRTC connection, an open device,
/// at every memory pressure) and the benefit of the doubt a page that does not answer keeps are the
/// rules of cmux-tui/crates/cmux-tab-discard (`probe`), asked through `PageProbe.keepReason` and
/// `PageProbe.keepsAwake` below. The rules hold each page's recent answers; the app tells them when
/// a page shows (`shown`) and closes (`forget`).
package struct PageProbe: Hashable, Sendable, Encodable {
    /// Unmuted media playing, media the tab's mute silences, or Picture in Picture.
    package var playingMedia = false
    /// The person's form edits in the tab's frames (`BrowserPageBusy.editedForm`).
    package var editedForm = false
    /// Camera, microphone or screen capture the page started (`BrowserPageBusy`).
    package var capturing = false
    /// A running Web Audio context.
    package var webAudio = false
    /// The page would ask before it unloads (a child frame's `BrowserPageBusy.beforeUnload`).
    package var beforeUnload = false
    /// The person used the top document and it has a `beforeunload` handler: it may ask. Not a keep
    /// reason by itself; the hibernation runs the handlers only right before the discard.
    package var unloadHandler = false
    /// A connected WebRTC peer connection.
    package var webRTC = false
    /// An open USB, HID or serial device, or a connected Bluetooth GATT server.
    package var connectedDevice = false
    /// The person moved into a child frame whose fields cannot be read.
    package var unreadableFrame = false
    /// False when the page did not answer (a script error, or no reply within the deadline).
    package var answered = true

    package init(playingMedia: Bool = false, editedForm: Bool = false, capturing: Bool = false, webAudio: Bool = false,
                 beforeUnload: Bool = false, unloadHandler: Bool = false, webRTC: Bool = false, connectedDevice: Bool = false, unreadableFrame: Bool = false,
                 answered: Bool = true) {
        self.playingMedia = playingMedia
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

    enum CodingKeys: String, CodingKey {
        case playingMedia = "playing_media", editedForm = "edited_form", capturing, webAudio = "web_audio"
        case beforeUnload = "before_unload", unloadHandler = "unload_handler", webRTC = "web_rtc"
        case connectedDevice = "connected_device", unreadableFrame = "unreadable_frame", answered
    }

    /// Why page `key` stays loaded now that it gave this answer right before a discard, or nil when it
    /// may go (`tab_discard_probe`; the rules record an answer). Rules that do not answer keep it.
    package func keepReason(_ key: String, pressure: MemoryPressureLevel, showsFormSubmission: Bool) -> HibernationPlanner.Exemption? {
        struct Request: Encodable {
            var key: String, probe: PageProbe, pressure: MemoryPressureLevel, showsFormSubmission: Bool
            enum CodingKeys: String, CodingKey { case key, probe, pressure, showsFormSubmission = "shows_form_submission" }
        }
        struct Reply: Decodable { var exemption: String? }
        let request = Request(key: key, probe: self, pressure: pressure, showsFormSubmission: showsFormSubmission)
        guard let reply = TabDiscardRules.call("tab_discard_probe", request, as: Reply.self) else { return .unanswered }
        return reply.exemption.map { HibernationPlanner.Exemption(rawValue: $0) ?? .unanswered }
    }

    /// Whether page `key` stays awake now that it gave this answer right before a freeze
    /// (`tab_discard_freeze_probe`; the rules record it). Rules that do not answer keep it awake.
    package func keepsAwake(_ key: String) -> Bool {
        struct Request: Encodable { var key: String, probe: PageProbe }
        struct Reply: Decodable { var keep: Bool }
        return TabDiscardRules.call("tab_discard_freeze_probe", Request(key: key, probe: self), as: Reply.self)?.keep ?? true
    }

    /// Page `key` showed: its missed probes start again (what it last said still holds).
    package static func shown(_ key: String) {
        struct Reply: Decodable {}
        _ = TabDiscardRules.call("tab_discard_shown", ["key": key], as: Reply.self)
    }

    /// Page `key` closed: the rules forget its answers.
    package static func forget(_ key: String) {
        struct Reply: Decodable {}
        _ = TabDiscardRules.call("tab_discard_forget", ["key": key], as: Reply.self)
    }
}
