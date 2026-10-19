import Foundation

/// Localized copy for the native Agent conversation surface.
///
/// Keep provider names, file names, commands, and transcript text outside this
/// namespace. They are data supplied by the host and are not translated here.
// lint:allow namespace-enum — shared localized copy is consumed by the mode, model, and usage card.
enum AgentChatStrings {
    // Navigation and session history.
    static let modeError = String(localized: "agent.chat.mode_error", defaultValue: "Agent mode error", bundle: .module)
    static let ok = String(localized: "agent.chat.ok", defaultValue: "OK", bundle: .module)
    static let unknownError = String(localized: "agent.chat.unknown_error", defaultValue: "Unknown error", bundle: .module)
    static let close = String(localized: "agent.chat.close", defaultValue: "Close", bundle: .module)
    static let agents = String(localized: "agent.chat.agents", defaultValue: "Agents", bundle: .module)
    static let pinned = String(localized: "agent.chat.pinned", defaultValue: "Pinned", bundle: .module)
    static let needsYourAttention = String(localized: "agent.chat.needs_your_attention", defaultValue: "Needs your attention", bundle: .module)
    static let recent = String(localized: "agent.chat.recent", defaultValue: "Recent", bundle: .module)
    static let archived = String(localized: "agent.chat.archived", defaultValue: "Archived", bundle: .module)
    static let searchSessions = String(localized: "agent.chat.search_sessions", defaultValue: "Search sessions", bundle: .module)
    static let agentHistory = String(localized: "agent.chat.agent_history", defaultValue: "Agent history", bundle: .module)
    static let newSession = String(localized: "agent.chat.new_session", defaultValue: "New session", bundle: .module)
    static let refreshSessions = String(localized: "agent.chat.refresh_sessions", defaultValue: "Refresh sessions", bundle: .module)
    static let provider = String(localized: "agent.chat.provider", defaultValue: "Provider", bundle: .module)
    static let allAgents = String(localized: "agent.chat.all_agents", defaultValue: "All agents", bundle: .module)
    static let claudeCode = String(localized: "agent.chat.claude_code", defaultValue: "Claude Code", bundle: .module)
    static let codex = String(localized: "agent.chat.codex", defaultValue: "Codex", bundle: .module)
    static let openCode = String(localized: "agent.chat.open_code", defaultValue: "OpenCode", bundle: .module)
    static let newAgentSessionAndFilters = String(localized: "agent.chat.new_agent_session_and_filters", defaultValue: "New agent session and filters", bundle: .module)
    static let agentSessions = String(localized: "agent.chat.agent_sessions", defaultValue: "Agent sessions", bundle: .module)
    static let refresh = String(localized: "agent.chat.refresh", defaultValue: "Refresh", bundle: .module)
    static let openingSideChat = String(localized: "agent.chat.opening_side_chat", defaultValue: "Opening side chat…", bundle: .module)
    static let forkSideChat = String(localized: "agent.chat.fork_side_chat", defaultValue: "Fork side chat", bundle: .module)
    static let resumeSession = String(localized: "agent.chat.resume_session", defaultValue: "Resume session", bundle: .module)
    static let reopenInTerminal = String(localized: "agent.chat.reopen_in_terminal", defaultValue: "Reopen in terminal", bundle: .module)
    static let renameSession = String(localized: "agent.chat.rename_session", defaultValue: "Rename session", bundle: .module)
    static let exporting = String(localized: "agent.chat.exporting", defaultValue: "Exporting…", bundle: .module)
    static let exportTranscript = String(localized: "agent.chat.export_transcript", defaultValue: "Export transcript", bundle: .module)
    static let deleteSession = String(localized: "agent.chat.delete_session", defaultValue: "Delete session", bundle: .module)
    static let agentModeOptions = String(localized: "agent.chat.agent_mode_options", defaultValue: "Agent mode options", bundle: .module)
    static let sessionName = String(localized: "agent.chat.session_name", defaultValue: "Session name", bundle: .module)
    static let untitledSession = String(localized: "agent.chat.untitled_session", defaultValue: "Untitled session", bundle: .module)
    static let cancel = String(localized: "agent.chat.cancel", defaultValue: "Cancel", bundle: .module)
    static let rename = String(localized: "agent.chat.rename", defaultValue: "Rename", bundle: .module)
    static let renameGuidance = String(localized: "agent.chat.rename_guidance", defaultValue: "Choose a name you will recognize in Agent history.", bundle: .module)
    static let deleteSessionConfirmation = String(localized: "agent.chat.delete_session_confirmation", defaultValue: "Delete this session?", bundle: .module)
    static let delete = String(localized: "agent.chat.delete", defaultValue: "Delete", bundle: .module)
    static let deleteSessionGuidance = String(localized: "agent.chat.delete_session_guidance", defaultValue: "The session will be removed from Agent history. Its provider transcript remains on your Mac.", bundle: .module)
    static let transcriptReadyToShare = String(localized: "agent.chat.transcript_ready_to_share", defaultValue: "Transcript ready to share", bundle: .module)
    static let shareTranscriptGuidance = String(localized: "agent.chat.share_transcript_guidance", defaultValue: "Send the Markdown transcript to Files, Messages, or another app.", bundle: .module)
    static let agentTranscript = String(localized: "agent.chat.agent_transcript", defaultValue: "Agent transcript", bundle: .module)
    static let shareTranscript = String(localized: "agent.chat.share_transcript", defaultValue: "Share transcript", bundle: .module)
    static let loadingAgentSessions = String(localized: "agent.chat.loading_agent_sessions", defaultValue: "Loading agent sessions…", bundle: .module)
    static let chooseAnAgentSession = String(localized: "agent.chat.choose_an_agent_session", defaultValue: "Choose an agent session", bundle: .module)
    static let reconnectingToYourMac = String(localized: "agent.chat.reconnecting_to_your_mac", defaultValue: "Reconnecting to your Mac", bundle: .module)
    static let selectSessionGuidance = String(localized: "agent.chat.select_session_guidance", defaultValue: "Select a session from Agent history to view its conversation.", bundle: .module)
    static let historyUnavailableGuidance = String(localized: "agent.chat.history_unavailable_guidance", defaultValue: "Your agent history will appear here when the connection is restored.", bundle: .module)
    static let tryAgain = String(localized: "agent.chat.try_again", defaultValue: "Try again", bundle: .module)
    static let noMatchingSessions = String(localized: "agent.chat.no_matching_sessions", defaultValue: "No matching sessions", bundle: .module)
    static let noAgentSessionsYet = String(localized: "agent.chat.no_agent_sessions_yet", defaultValue: "No agent sessions yet", bundle: .module)
    static let waitingForConnection = String(localized: "agent.chat.waiting_for_connection", defaultValue: "Waiting for a connection", bundle: .module)
    static let searchNoMatchGuidance = String(localized: "agent.chat.search_no_match_guidance", defaultValue: "Try a different name, project, or provider.", bundle: .module)
    static let startSessionGuidance = String(localized: "agent.chat.start_session_guidance", defaultValue: "Start Claude Code, Codex, or OpenCode in cmux to see it here.", bundle: .module)
    static let reconnectHistoryGuidance = String(localized: "agent.chat.reconnect_history_guidance", defaultValue: "Reconnect to your Mac to load agent history.", bundle: .module)
    static let clearSearch = String(localized: "agent.chat.clear_search", defaultValue: "Clear search", bundle: .module)
    static let startNewSession = String(localized: "agent.chat.start_new_session", defaultValue: "Start a new session", bundle: .module)
    static let loadingSessions = String(localized: "agent.chat.loading_sessions", defaultValue: "Loading sessions…", bundle: .module)
    static let connectedToYourMac = String(localized: "agent.chat.connected_to_your_mac", defaultValue: "Connected to your Mac", bundle: .module)
    static let reconnectingToYourMacWithEllipsis = String(localized: "agent.chat.reconnecting_to_your_mac_ellipsis", defaultValue: "Reconnecting to your Mac…", bundle: .module)
    static let retry = String(localized: "agent.chat.retry", defaultValue: "Retry", bundle: .module)
    static let unpinSession = String(localized: "agent.chat.unpin_session", defaultValue: "Unpin session", bundle: .module)
    static let pinSession = String(localized: "agent.chat.pin_session", defaultValue: "Pin session", bundle: .module)
    static let unarchiveSession = String(localized: "agent.chat.unarchive_session", defaultValue: "Unarchive session", bundle: .module)
    static let archiveSession = String(localized: "agent.chat.archive_session", defaultValue: "Archive session", bundle: .module)
    static let loadEarlierMessages = String(localized: "agent.chat.load_earlier_messages", defaultValue: "Load earlier messages", bundle: .module)

    static let usageAndContext = String(localized: "agent.chat.usage_and_context", defaultValue: "Usage and context", bundle: .module)
    static let usageUnavailable = String(localized: "agent.chat.usage_unavailable", defaultValue: "Usage unavailable", bundle: .module)
    static let limitReached = String(localized: "agent.chat.limit_reached", defaultValue: "Limit reached", bundle: .module)

    // Conversation, turn state, and cards.
    static let working = String(localized: "agent.chat.working", defaultValue: "Working", bundle: .module)
    static let needsInput = String(localized: "agent.chat.needs_input", defaultValue: "Needs input", bundle: .module)
    static let turnFailedRetryAvailable = String(localized: "agent.chat.turn_failed_retry_available", defaultValue: "Turn failed; retry available", bundle: .module)
    static let idle = String(localized: "agent.chat.idle", defaultValue: "Idle", bundle: .module)
    static let ended = String(localized: "agent.chat.ended", defaultValue: "Ended", bundle: .module)
    static let startTask = String(localized: "agent.chat.start_task", defaultValue: "Start a task", bundle: .module)
    static let startTaskGuidance = String(localized: "agent.chat.start_task_guidance", defaultValue: "Ask your coding agent to inspect, change, or explain your project.", bundle: .module)
    static let attachment = String(localized: "agent.chat.attachment", defaultValue: "Attachment", bundle: .module)
    static let queuedForNextTurn = String(localized: "agent.chat.queued_for_next_turn", defaultValue: "Queued for the next turn", bundle: .module)
    static let sending = String(localized: "agent.chat.sending", defaultValue: "Sending…", bundle: .module)
    static let yourInputIsNeeded = String(localized: "agent.chat.your_input_is_needed", defaultValue: "Your input is needed", bundle: .module)
    static let answerOrApproveGuidance = String(localized: "agent.chat.answer_or_approve_guidance", defaultValue: "Answer the agent's question or approve its next action below.", bundle: .module)
    static let reviewPendingRequestGuidance = String(localized: "agent.chat.review_pending_request_guidance", defaultValue: "Review the pending request below to keep the task moving.", bundle: .module)
    static let agentDidNotCompleteTurn = String(localized: "agent.chat.agent_did_not_complete_turn", defaultValue: "The agent did not complete this turn.", bundle: .module)
    static let turnFailed = String(localized: "agent.chat.turn_failed", defaultValue: "Turn failed", bundle: .module)
    static let retryingFailedTurn = String(localized: "agent.chat.retrying_failed_turn", defaultValue: "Retrying failed turn", bundle: .module)
    static let retryFailedTurn = String(localized: "agent.chat.retry_failed_turn", defaultValue: "Retry failed turn", bundle: .module)
    static let model = String(localized: "agent.chat.model", defaultValue: "Model", bundle: .module)
    static let reasoningEffort = String(localized: "agent.chat.reasoning_effort", defaultValue: "Reasoning effort", bundle: .module)
    static let permissionMode = String(localized: "agent.chat.permission_mode", defaultValue: "Permission mode", bundle: .module)
    static let sandbox = String(localized: "agent.chat.sandbox", defaultValue: "Sandbox", bundle: .module)
    static let planMode = String(localized: "agent.chat.plan_mode", defaultValue: "Plan mode", bundle: .module)
    static let controls = String(localized: "agent.chat.controls", defaultValue: "Controls", bundle: .module)
    static let editPrompt = String(localized: "agent.chat.edit_prompt", defaultValue: "Edit prompt", bundle: .module)
    static let regeneratingResponse = String(localized: "agent.chat.regenerating_response", defaultValue: "Regenerating response…", bundle: .module)
    static let regenerateResponse = String(localized: "agent.chat.regenerate_response", defaultValue: "Regenerate response", bundle: .module)
    static let copy = String(localized: "agent.chat.copy", defaultValue: "Copy", bundle: .module)
    static let share = String(localized: "agent.chat.share", defaultValue: "Share", bundle: .module)
    static let shell = String(localized: "agent.chat.shell", defaultValue: "Shell", bundle: .module)
    static let thinking = String(localized: "agent.chat.thinking", defaultValue: "Thinking", bundle: .module)
    static let input = String(localized: "agent.chat.input", defaultValue: "Input", bundle: .module)
    static let output = String(localized: "agent.chat.output", defaultValue: "Output", bundle: .module)
    static let toolIsRunning = String(localized: "agent.chat.tool_is_running", defaultValue: "Tool is running", bundle: .module)
    static let running = String(localized: "agent.chat.running", defaultValue: "Running", bundle: .module)
    static let done = String(localized: "agent.chat.done", defaultValue: "Done", bundle: .module)
    static let failed = String(localized: "agent.chat.failed", defaultValue: "Failed", bundle: .module)
    static let sources = String(localized: "agent.chat.sources", defaultValue: "Sources", bundle: .module)
    static let searching = String(localized: "agent.chat.searching", defaultValue: "Searching", bundle: .module)
    static let noSourcesReturned = String(localized: "agent.chat.no_sources_returned", defaultValue: "No sources returned", bundle: .module)
    static let viewDiff = String(localized: "agent.chat.view_diff", defaultValue: "View diff", bundle: .module)
    static let apply = String(localized: "agent.chat.apply", defaultValue: "Apply", bundle: .module)
    static let revert = String(localized: "agent.chat.revert", defaultValue: "Revert", bundle: .module)
    static let commentOnLine = String(localized: "agent.chat.comment_on_line", defaultValue: "Comment on a line", bundle: .module)
    static let line = String(localized: "agent.chat.line", defaultValue: "Line", bundle: .module)
    static let reviewComment = String(localized: "agent.chat.review_comment", defaultValue: "Review comment", bundle: .module)
    static let send = String(localized: "agent.chat.send", defaultValue: "Send", bundle: .module)
    static let diffUnavailable = String(localized: "agent.chat.diff_unavailable", defaultValue: "Diff unavailable", bundle: .module)
    static let diffMissingGuidance = String(localized: "agent.chat.diff_missing_guidance", defaultValue: "The agent changed this file, but the host did not provide a reviewable diff.", bundle: .module)
    static let currentFile = String(localized: "agent.chat.current_file", defaultValue: "Current file", bundle: .module)
    static let edited = String(localized: "agent.chat.edited", defaultValue: "Edited", bundle: .module)
    static let created = String(localized: "agent.chat.created", defaultValue: "Created", bundle: .module)
    static let deleted = String(localized: "agent.chat.deleted", defaultValue: "Deleted", bundle: .module)
    static let hidePreview = String(localized: "agent.chat.hide_preview", defaultValue: "Hide preview", bundle: .module)
    static let preview = String(localized: "agent.chat.preview", defaultValue: "Preview", bundle: .module)

    // Permissions, questions, and composer.
    static let sendingDecision = String(localized: "agent.chat.sending_decision", defaultValue: "Sending decision…", bundle: .module)
    static let scope = String(localized: "agent.chat.scope", defaultValue: "Scope", bundle: .module)
    static let allowedOnce = String(localized: "agent.chat.allowed_once", defaultValue: "Allowed once", bundle: .module)
    static let alwaysAllowed = String(localized: "agent.chat.always_allowed", defaultValue: "Always allowed", bundle: .module)
    static let allMatchingActionsAllowed = String(localized: "agent.chat.all_matching_actions_allowed", defaultValue: "All matching actions allowed", bundle: .module)
    static let denied = String(localized: "agent.chat.denied", defaultValue: "Denied", bundle: .module)
    static let expired = String(localized: "agent.chat.expired", defaultValue: "Expired", bundle: .module)
    static let planReadyForReview = String(localized: "agent.chat.plan_ready_for_review", defaultValue: "Plan ready for review", bundle: .module)
    static let sendingAnswer = String(localized: "agent.chat.sending_answer", defaultValue: "Sending answer…", bundle: .module)
    static let submitSelection = String(localized: "agent.chat.submit_selection", defaultValue: "Submit selection", bundle: .module)
    static let typeAnAnswer = String(localized: "agent.chat.type_an_answer", defaultValue: "Or type an answer", bundle: .module)
    static let preparingAttachments = String(localized: "agent.chat.preparing_attachments", defaultValue: "Preparing attachments", bundle: .module)
    static let settings = String(localized: "agent.chat.settings", defaultValue: "Settings", bundle: .module)
    static let sessionEnded = String(localized: "agent.chat.session_ended", defaultValue: "Session ended", bundle: .module)
    static let messageYourAgent = String(localized: "agent.chat.message_your_agent", defaultValue: "Message your agent", bundle: .module)
    static let photoLibrary = String(localized: "agent.chat.photo_library", defaultValue: "Photo Library", bundle: .module)
    static let pasteImage = String(localized: "agent.chat.paste_image", defaultValue: "Paste Image", bundle: .module)
    static let chooseFile = String(localized: "agent.chat.choose_file", defaultValue: "Choose File", bundle: .module)
    static let addAttachment = String(localized: "agent.chat.add_attachment", defaultValue: "Add attachment", bundle: .module)
    static let stopDictation = String(localized: "agent.chat.stop_dictation", defaultValue: "Stop dictation", bundle: .module)
    static let startDictation = String(localized: "agent.chat.start_dictation", defaultValue: "Start dictation", bundle: .module)
    static let stopTurn = String(localized: "agent.chat.stop_turn", defaultValue: "Stop turn", bundle: .module)
    static let forceStop = String(localized: "agent.chat.force_stop", defaultValue: "Force stop", bundle: .module)
    static let stopAgent = String(localized: "agent.chat.stop_agent", defaultValue: "Stop agent", bundle: .module)
    static let stopAgentGuidance = String(localized: "agent.chat.stop_agent_guidance", defaultValue: "Choose a polite or forceful interruption", bundle: .module)
    static let queueForNextTurn = String(localized: "agent.chat.queue_for_next_turn", defaultValue: "Queue for next turn", bundle: .module)
    static let steerCurrentTurn = String(localized: "agent.chat.steer_current_turn", defaultValue: "Steer current turn", bundle: .module)
    static let sendInstruction = String(localized: "agent.chat.send_instruction", defaultValue: "Send instruction", bundle: .module)
    static let sendInstructionGuidance = String(localized: "agent.chat.send_instruction_guidance", defaultValue: "Choose whether to queue the instruction or steer the current turn", bundle: .module)
    static let readOnlySession = String(localized: "agent.chat.read_only_session", defaultValue: "This agent session has ended and is read only.", bundle: .module)
    static let photo = String(localized: "agent.chat.photo", defaultValue: "Photo", bundle: .module)
    static let imageCouldNotBePrepared = String(localized: "agent.chat.image_could_not_be_prepared", defaultValue: "That image could not be prepared.", bundle: .module)
    static let someImagesCouldNotBePrepared = String(localized: "agent.chat.some_images_could_not_be_prepared", defaultValue: "Some images could not be prepared.", bundle: .module)
    static let fileCouldNotBeAttached = String(localized: "agent.chat.file_could_not_be_attached", defaultValue: "That file could not be attached. Files must be 32 MB or smaller.", bundle: .module)
    static let someFilesCouldNotBeAttached = String(localized: "agent.chat.some_files_could_not_be_attached", defaultValue: "Some files could not be attached. Files must be 32 MB or smaller.", bundle: .module)
    static let waiting = String(localized: "agent.chat.waiting", defaultValue: "Waiting", bundle: .module)
    static let loading = String(localized: "agent.chat.loading", defaultValue: "Loading", bundle: .module)
    static let preparing = String(localized: "agent.chat.preparing", defaultValue: "Preparing", bundle: .module)
    static let ready = String(localized: "agent.chat.ready", defaultValue: "Ready", bundle: .module)
    static let couldNotAttach = String(localized: "agent.chat.could_not_attach", defaultValue: "Couldn’t attach", bundle: .module)
    static let cancelled = String(localized: "agent.chat.cancelled", defaultValue: "Cancelled", bundle: .module)
    static let preparingPreview = String(localized: "agent.chat.preparing_preview", defaultValue: "Preparing preview…", bundle: .module)
    static let previewUnavailableForFileType = String(localized: "agent.chat.preview_unavailable_for_file_type", defaultValue: "Preview is unavailable for this file type.", bundle: .module)
    static let microphonePermissionGuidance = String(localized: "agent.chat.microphone_permission_guidance", defaultValue: "Allow microphone and speech recognition to dictate.", bundle: .module)
    static let listening = String(localized: "agent.chat.listening", defaultValue: "Listening… speak your next instruction.", bundle: .module)
    static let finishingDictation = String(localized: "agent.chat.finishing_dictation", defaultValue: "Finishing dictation…", bundle: .module)
    static let dictationUnavailable = String(localized: "agent.chat.dictation_unavailable", defaultValue: "Dictation is unavailable. Enable microphone and speech access in Settings.", bundle: .module)
    static let enterSessionName = String(localized: "agent.chat.enter_session_name", defaultValue: "Enter a name for this session.", bundle: .module)
    static let maxAttachmentsReached = String(localized: "agent.chat.max_attachments_reached", defaultValue: "You can attach up to 10 attachments.", bundle: .module)
    static let fileTooLargeToSend = String(localized: "agent.chat.file_too_large_to_send", defaultValue: "That file is too large to send.", bundle: .module)
    static let imageTooLargeToSend = String(localized: "agent.chat.image_too_large_to_send", defaultValue: "That image is too large to send.", bundle: .module)
    static let attachmentsTotalLimit = String(localized: "agent.chat.attachments_total_limit", defaultValue: "Attachments can use up to 64 MB in total.", bundle: .module)
    static let noImageToPaste = String(localized: "agent.chat.no_image_to_paste", defaultValue: "No image is available to paste.", bundle: .module)
    static let maxImagesReached = String(localized: "agent.chat.max_images_reached", defaultValue: "You can attach up to 10 images.", bundle: .module)
    static let imageCouldNotBePreparedForPaste = String(localized: "agent.chat.image_could_not_be_prepared_for_paste", defaultValue: "That image couldn’t be prepared. Choose another image.", bundle: .module)
    static func pastedImage(_ index: Int) -> String {
        let format = String(localized: "agent.chat.pasted_image", defaultValue: "Pasted image %lld", bundle: .module)
        return String(format: format, locale: Locale.current, index)
    }

    // Dynamic labels keep provider and transcript data intact while
    // localizing the surrounding copy. These use localized format strings so
    // translators can reorder values for languages that need it.
    static func contextPercent(_ percent: Int) -> String {
        let format = String(localized: "agent.chat.context_percent", defaultValue: "%lld%% context", bundle: .module)
        return String(format: format, locale: Locale.current, percent)
    }

    static func contextTokens(_ value: String) -> String {
        let format = String(localized: "agent.chat.context_tokens", defaultValue: "%@ context tokens", bundle: .module)
        return String(format: format, locale: Locale.current, value)
    }

    static func totalTokens(_ value: String) -> String {
        let format = String(localized: "agent.chat.total_tokens", defaultValue: "%@ tokens", bundle: .module)
        return String(format: format, locale: Locale.current, value)
    }

    static func allowancePercent(_ percent: Int) -> String {
        let format = String(localized: "agent.chat.allowance_percent", defaultValue: "%lld%% allowance", bundle: .module)
        return String(format: format, locale: Locale.current, percent)
    }

    static func resets(_ relative: String) -> String {
        let format = String(localized: "agent.chat.resets", defaultValue: "Resets %@", bundle: .module)
        return String(format: format, locale: Locale.current, relative)
    }

    static func usageAccessibility(_ labels: String) -> String {
        let format = String(localized: "agent.chat.usage_accessibility", defaultValue: "Usage and context, %@", bundle: .module)
        return String(format: format, locale: Locale.current, labels)
    }

    static func relativeMinutes(_ minutes: Int) -> String {
        let format = String(localized: "agent.chat.relative_minutes", defaultValue: "in %lldm", bundle: .module)
        return String(format: format, locale: Locale.current, minutes)
    }

    static func relativeHours(_ hours: Int) -> String {
        let format = String(localized: "agent.chat.relative_hours", defaultValue: "in %lldh", bundle: .module)
        return String(format: format, locale: Locale.current, hours)
    }

    static func relativeDays(_ days: Int) -> String {
        let format = String(localized: "agent.chat.relative_days", defaultValue: "in %lldd", bundle: .module)
        return String(format: format, locale: Locale.current, days)
    }

    static func unsupportedEvent(_ rawType: String) -> String {
        let format = String(localized: "agent.chat.unsupported_event", defaultValue: "Unsupported agent event: %@", bundle: .module)
        return String(format: format, locale: Locale.current, rawType)
    }

    static func searchQuery(_ query: String) -> String {
        let format = String(localized: "agent.chat.search_query", defaultValue: "Search %@", bundle: .module)
        return String(format: format, locale: Locale.current, query)
    }

    static func exitCode(_ code: Int) -> String {
        let format = String(localized: "agent.chat.exit_code", defaultValue: "Exit %lld", bundle: .module)
        return String(format: format, locale: Locale.current, code)
    }

    static func sessionAccessibility(agent: String, title: String, state: String) -> String {
        let format = String(localized: "agent.chat.session_accessibility", defaultValue: "%@, %@, %@", bundle: .module)
        return String(format: format, locale: Locale.current, agent, title, state)
    }

    static func queuedAccessibility(_ content: String) -> String {
        let format = String(localized: "agent.chat.queued_accessibility", defaultValue: "Queued: %@", bundle: .module)
        return String(format: format, locale: Locale.current, content)
    }

    static func sendingAccessibility(_ content: String) -> String {
        let format = String(localized: "agent.chat.sending_accessibility", defaultValue: "Sending: %@", bundle: .module)
        return String(format: format, locale: Locale.current, content)
    }

    static func pendingRequests(_ count: Int) -> String {
        let format = String(localized: "agent.chat.pending_requests", defaultValue: "Review the %lld pending requests below to keep the task moving.", bundle: .module)
        return String(format: format, locale: Locale.current, count)
    }

    static func answered(_ selection: String) -> String {
        let format = String(localized: "agent.chat.answered", defaultValue: "Answered: %@", bundle: .module)
        return String(format: format, locale: Locale.current, selection)
    }

    static func preparingAttachments(_ count: Int) -> String {
        if count == 1 {
            return String(localized: "agent.chat.preparing_attachment", defaultValue: "Preparing 1 attachment", bundle: .module)
        }
        let format = String(localized: "agent.chat.preparing_attachments_count", defaultValue: "Preparing %lld attachments", bundle: .module)
        return String(format: format, locale: Locale.current, count)
    }

    static func queuedMessages(_ count: Int) -> String {
        if count == 1 {
            return String(localized: "agent.chat.message_queued", defaultValue: "1 message queued", bundle: .module)
        }
        let format = String(localized: "agent.chat.messages_queued", defaultValue: "%lld messages queued", bundle: .module)
        return String(format: format, locale: Locale.current, count)
    }

    static func scope(_ value: String) -> String {
        let format = String(localized: "agent.chat.scope_value", defaultValue: "Scope: %@", bundle: .module)
        return String(format: format, locale: Locale.current, value)
    }

    static func attachmentProgress(_ percent: Int) -> String {
        let format = String(localized: "agent.chat.attachment_progress", defaultValue: "%lld%%", bundle: .module)
        return String(format: format, locale: Locale.current, percent)
    }

    static func previewAttachment(_ name: String) -> String {
        let format = String(localized: "agent.chat.preview_attachment", defaultValue: "Preview %@", bundle: .module)
        return String(format: format, locale: Locale.current, name)
    }

    static func removeAttachment(_ name: String) -> String {
        let format = String(localized: "agent.chat.remove_attachment", defaultValue: "Remove %@", bundle: .module)
        return String(format: format, locale: Locale.current, name)
    }

    static let sessionStarted = String(localized: "agent.chat.session_started", defaultValue: "Session started", bundle: .module)
    static let sessionEndedStatus = String(localized: "agent.chat.session_ended_status", defaultValue: "Session ended", bundle: .module)
    static let turnInterrupted = String(localized: "agent.chat.turn_interrupted", defaultValue: "Turn interrupted", bundle: .module)
    static let contextCompacted = String(localized: "agent.chat.context_compacted", defaultValue: "Context compacted", bundle: .module)
}
