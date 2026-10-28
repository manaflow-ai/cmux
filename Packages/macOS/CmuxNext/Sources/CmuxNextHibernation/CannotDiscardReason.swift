/// Why content is not discarded now: one value per reason, reported by `debug.surfaces` (browser
/// pages) and `debug.discards` by its raw value.
///
/// Chrome's `chrome/browser/performance_manager/policies/cannot_discard_reason.h` has 30 reasons;
/// each maps to one case here (``init(chromeReason:)``). Where cmux already had a reason for the
/// same fact it keeps cmux's name and raw value (Chrome's `kPinnedTab` is ``pinned``, the four
/// `kCapturing*` reasons are ``capturing``). The other cases are cmux's own: the probe's answers
/// (``webAudio``, ``beforeUnload``, ``unanswered``), agents (``agentLease``, ``agentDriving``,
/// ``agentBusy``), the neighbor tabs, and ``unsavedEdits``, ``runningCommand``, ``inProgress`` and ``openPanel``
/// for the non-browser kinds.
///
/// The raw values of the cases browser hibernation reported before ``ContentDiscardPlanner`` are
/// unchanged; scripts and benches read them.
package nonisolated enum CannotDiscardReason: String, Hashable, Sendable, CaseIterable {
    case disabled, excluded, pinned, devTools = "devtools", capturing, unsupported
    /// Found by the probe right before hibernating.
    case audio, formInput = "form_input"
    /// A running Web Audio context, at every memory pressure.
    case webAudio = "web_audio"
    /// The page would ask before it unloads (a `beforeunload` that cancels, after the person
    /// used the page or a child frame with a handler that the person used).
    case beforeUnload = "before_unload"
    /// A connected WebRTC peer connection.
    case webRTC = "web_rtc"
    /// An open USB, HID or serial device, or a connected Bluetooth GATT server.
    case connectedDevice = "connected_device"
    /// The person moved into a child frame whose fields cannot be read (Chromium's cross-origin frames).
    case unreadableFrame = "unreadable_frame"
    /// The page's site may show notifications; kept from the timeout, not from memory pressure.
    case notifications
    /// An agent chat whose agent works or waits on the person (AgentPageHibernation).
    case agentBusy = "agent_busy"
    /// The acpmux turn watch is down, so no chat's turn is known: every chat counts as busy.
    case agentTurnsUnknown = "agent_turns_unknown"
    case formSubmission = "form_submission"  // the page shows a form result (BR-R1)
    /// An agent called the page within `BrowserHibernation.agentGrace` (`cmux browser`, MCP, the REPL).
    case agentDriving = "agent_driving"
    /// Beside a pane's shown tab, or hovered (`browser.keepNeighborTabsAwake`).
    case neighbor
    /// The page did not answer the probe: kept for `PageProbeHistory.unansweredLimit`
    /// probes in a row, then until memory pressure (its form edits are unknown). A page whose
    /// last answer kept it stays for as long as it does not answer.
    case unanswered
    /// A download the page started still runs.
    case downloading
    /// An agent holds the page's browser lease.
    case agentLease = "agent_lease"
    /// cmux.json does not set `browser.hibernation`: hidden pages only freeze, so they keep their
    /// state, and are never discarded on their own (`BrowserHibernationSetting.discardsAutomatically`).
    case keepsState = "keeps_state"

    /// The content is not something the planner discards (Chrome's `kNotATab`).
    case notATab = "not_a_tab"
    /// The content is discarded already (Chrome's `kAlreadyDiscarded`).
    case alreadyDiscarded = "already_discarded"
    /// A discard of this content was tried and did not finish; it stays until shown again
    /// (Chrome's `kDiscardAttempted`, the `DiscardAttemptMarker` of `page_discarding_helper.cc`).
    case discardAttempted = "discard_attempted"
    /// The content has no main document yet (Chrome's `kNoMainFrame`).
    case noMainFrame = "no_main_frame"
    /// The content shows now (Chrome's `kVisible`).
    case visible
    /// Audio ended within the last minute (Chrome's `kRecentlyAudible`, `kTabAudioProtectionTime`).
    case recentlyAudible = "recently_audible"
    /// The content was shown too recently (Chrome's `kRecentlyVisible`).
    case recentlyVisible = "recently_visible"
    /// The content plays in Picture in Picture (Chrome's `kPictureInPicture`).
    case pictureInPicture = "picture_in_picture"
    /// The content is a PDF (Chrome's `kPdf`).
    case pdf
    /// The content's URL is not a web or cmux page (Chrome's `kNotWebOrInternal`).
    case notWebOrInternal = "not_web_or_internal"
    /// The content's URL is not valid (Chrome's `kInvalidURL`).
    case invalidURL = "invalid_url"
    /// An extension asked to keep the content (Chrome's `kExtensionProtected`).
    case extensionProtected = "extension_protected"
    /// The content is mirrored to another screen (Chrome's `kBeingMirrored`).
    case beingMirrored = "being_mirrored"
    /// The content is its window's active tab (Chrome's `kActiveTab`).
    case activeTab = "active_tab"
    /// The content changed its title or icon while hidden (Chrome's `kBackgroundActivity`).
    case backgroundActivity = "background_activity"
    /// The content is an installed web app's window (Chrome's `kWebApp`).
    case webApp = "web_app"
    /// The content holds edits the person has not saved: an editor buffer, a draft, a page's
    /// edited document (Chrome's `kUserEdits`).
    case unsavedEdits = "unsaved_edits"
    /// A terminal's command still runs.
    case runningCommand = "running_command"
    /// The content waits on a step the person started from it and that only it shows the end of:
    /// a machine being created, a pairing code being scanned, a reply being sent. Chrome has no
    /// such reason: its pages keep such work in a network request that a discard cancels.
    case inProgress = "in_progress"
    /// A window the content opened still shows (a Files pane's Get Info panel): its discard would
    /// close it. Chrome keeps a tab whose DevTools window is open the same way (`kDevToolsOpen`).
    case openPanel = "open_panel"

    /// The case of Chrome's reason `name` (the enumerator's name in `cannot_discard_reason.h`, such
    /// as `kPinnedTab`), or nil when Chrome has no such reason.
    ///
    /// - Parameter name: A `CannotDiscardReason` enumerator of Chrome.
    package init?(chromeReason name: String) {
        switch name {
        case "kNotATab": self = .notATab
        case "kAlreadyDiscarded": self = .alreadyDiscarded
        case "kDiscardAttempted": self = .discardAttempted
        case "kNoMainFrame": self = .noMainFrame
        case "kVisible": self = .visible
        case "kAudible": self = .audio
        case "kRecentlyAudible": self = .recentlyAudible
        case "kRecentlyVisible": self = .recentlyVisible
        case "kPictureInPicture": self = .pictureInPicture
        case "kPdf": self = .pdf
        case "kNotWebOrInternal": self = .notWebOrInternal
        case "kInvalidURL": self = .invalidURL
        case "kOptedOut": self = .excluded
        case "kNotificationsEnabled": self = .notifications
        case "kExtensionProtected": self = .extensionProtected
        case "kCapturingVideo", "kCapturingAudio", "kCapturingWindow", "kCapturingDisplay": self = .capturing
        case "kBeingMirrored": self = .beingMirrored
        case "kConnectedToBluetooth", "kConnectedToUSB": self = .connectedDevice
        case "kActiveTab": self = .activeTab
        case "kPinnedTab": self = .pinned
        case "kDevToolsOpen": self = .devTools
        case "kBackgroundActivity": self = .backgroundActivity
        case "kFormInteractions": self = .formInput
        case "kUserEdits": self = .unsavedEdits
        // Chrome's Glic shares a tab with its assistant; cmux's agents hold a page through its lease.
        case "kGlicShared": self = .agentLease
        case "kWebApp": self = .webApp
        default: return nil
        }
    }
}
