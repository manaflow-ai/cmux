/// Why content cannot be discarded now. The first 30 cases are Chrome's
/// (chrome/browser/performance_manager/policies/cannot_discard_reason.h), with their names in
/// snake case. The rest are cmux's: a `HibernationPlanner.Exemption` with no Chrome reason keeps
/// the raw value `debug.surfaces` shows.
package enum CannotDiscardReason: String, CaseIterable, Hashable, Sendable {
    case notATab = "not_a_tab", alreadyDiscarded = "already_discarded", discardAttempted = "discard_attempted"
    case noMainFrame = "no_main_frame", visible, audible, recentlyAudible = "recently_audible"
    case recentlyVisible = "recently_visible", pictureInPicture = "picture_in_picture", pdf
    case notWebOrInternal = "not_web_or_internal", invalidURL = "invalid_url", optedOut = "opted_out"
    case notificationsEnabled = "notifications_enabled", extensionProtected = "extension_protected"
    case capturingVideo = "capturing_video", capturingAudio = "capturing_audio", capturingWindow = "capturing_window"
    case capturingDisplay = "capturing_display", beingMirrored = "being_mirrored"
    case connectedToBluetooth = "connected_to_bluetooth", connectedToUSB = "connected_to_usb", activeTab = "active_tab"
    case pinnedTab = "pinned_tab", devToolsOpen = "devtools_open", backgroundActivity = "background_activity"
    case formInteractions = "form_interactions", userEdits = "user_edits", glicShared = "glic_shared", webApp = "web_app"

    // cmux reasons.
    /// Discarding is off (`browser.hibernation` "off").
    case disabled
    /// Camera, microphone or screen capture, as Page Info reports it.
    case capturing
    /// The engine cannot save and restore the content.
    case unsupported
    case webAudio = "web_audio", beforeUnload = "before_unload", webRTC = "web_rtc", connectedDevice = "connected_device"
    case unreadableFrame = "unreadable_frame", agentBusy = "agent_busy", agentTurnsUnknown = "agent_turns_unknown"
    case formSubmission = "form_submission", agentDriving = "agent_driving", neighbor, unanswered, downloading
    case agentLease = "agent_lease"
    /// Edits not saved anywhere else (a file page, a note).
    case unsavedEdits = "unsaved_edits"
    /// A command runs in it.
    case runningCommand = "running_command"
    /// It is hidden, but no planner pass has judged it since it hid.
    case notPlanned = "not_planned"
    /// No owner discards content of this kind yet.
    case noPolicy = "no_policy"

    /// The reason a browser or agent page exemption gives. The Chrome name where Chrome has the
    /// same reason, otherwise the exemption's own raw value.
    package init(_ exemption: HibernationPlanner.Exemption) {
        switch exemption {
        case .excluded: self = .optedOut
        case .pinned: self = .pinnedTab
        case .devTools: self = .devToolsOpen
        case .audio: self = .audible
        case .formInput: self = .formInteractions
        case .notifications: self = .notificationsEnabled
        case .disabled: self = .disabled
        case .capturing: self = .capturing
        case .unsupported: self = .unsupported
        case .webAudio: self = .webAudio
        case .beforeUnload: self = .beforeUnload
        case .webRTC: self = .webRTC
        case .connectedDevice: self = .connectedDevice
        case .unreadableFrame: self = .unreadableFrame
        case .agentBusy: self = .agentBusy
        case .agentTurnsUnknown: self = .agentTurnsUnknown
        case .formSubmission: self = .formSubmission
        case .agentDriving: self = .agentDriving
        case .neighbor: self = .neighbor
        case .unanswered: self = .unanswered
        case .downloading: self = .downloading
        case .agentLease: self = .agentLease
        }
    }
}

/// Chrome's CanDiscardResult (discard_eligibility_policy.h). Urgent and proactive discards never
/// take protected content (`DiscardAPage` passes `discard_protected_tabs=false`); only an external
/// discard can. Nothing takes disallowed content.
package enum CanDiscardResult: Hashable, Sendable {
    case eligible
    case protected(CannotDiscardReason)
    case disallowed(CannotDiscardReason)

    /// What a browser or agent page exemption allows. The person's Hibernate Tab still takes the
    /// page (protected), except when its engine cannot restore it or it shows a form result
    /// (disallowed: `BrowserHibernation.hibernateNow` refuses both).
    package init(_ exemption: HibernationPlanner.Exemption) {
        switch exemption {
        case .unsupported, .formSubmission: self = .disallowed(CannotDiscardReason(exemption))
        default: self = .protected(CannotDiscardReason(exemption))
        }
    }

    /// Why it cannot be discarded; nil when it is eligible.
    package var reason: CannotDiscardReason? {
        switch self {
        case .eligible: nil
        case .protected(let reason), .disallowed(let reason): reason
        }
    }
}
