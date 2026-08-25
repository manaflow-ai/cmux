import Foundation

/// Fixed terminal-toolbar actions stored in the value payload of
/// ``DiagnosticAppEventKind/terminalToolbarActionUsed``.
///
/// Values 0...31 mirror the persisted `TerminalInputAccessoryAction` raw
/// values. Values starting at 100 are fixed controls outside that configurable
/// action list. Append only, because these values ship in diagnostic reports.
public enum DiagnosticTerminalToolbarAction: Int, Sendable, Codable, CaseIterable {
    case control = 0
    case alternate = 1
    case command = 2
    case shift = 3
    case zoomOut = 4
    case zoomIn = 5
    case escape = 6
    case tab = 7
    case upArrow = 8
    case downArrow = 9
    case leftArrow = 10
    case rightArrow = 11
    case claude = 12
    case codex = 13
    case tilde = 14
    case pipe = 15
    case dollar = 16
    case slash = 17
    case atSign = 18
    case ctrlC = 19
    case ctrlD = 20
    case ctrlZ = 21
    case ctrlL = 22
    case home = 23
    case end = 24
    case pageUp = 25
    case pageDown = 26
    case paste = 27
    case composer = 28
    case returnKey = 29
    case ollama = 30
    case files = 31
    case keyboardToggle = 100
    case hideChrome = 101
    case customize = 102
    case zoomResetToDefault = 103
    case zoomSaveAsDefault = 104
    case zoomRestoreBuiltIn = 105
}

/// Fixed reason stored in the value payload of
/// ``DiagnosticAppEventKind/terminalZoomChanged``.
public enum DiagnosticTerminalZoomAction: Int, Sendable, Codable, CaseIterable {
    case stepDecrease = 1
    case stepIncrease = 2
    case resetToDefault = 3
    case restoreBuiltIn = 4
    case hostSet = 5
}

/// Fixed primary navigation destination stored in the value payload of
/// ``DiagnosticAppEventKind/primaryTabSelected``.
public enum DiagnosticPrimaryTab: Int, Sendable, Codable, CaseIterable {
    case workspaces = 1
    case notifications = 2
    case search = 3
}

/// Fixed search owner stored in the value payload of search lifecycle events.
public enum DiagnosticSearchScope: Int, Sendable, Codable, CaseIterable {
    case workspaces = 1
    case notifications = 2
}

/// Fixed mutations stored in the value payload of terminal toolbar settings
/// events. The custom-action cases report only the operation, never the action's
/// user-authored label or inserted text.
public enum DiagnosticToolbarConfigurationAction: Int, Sendable, Codable, CaseIterable {
    case shortcutShown = 1
    case shortcutHidden = 2
    case shortcutReordered = 3
    case shortcutsReset = 4
    case customActionAdded = 10
    case customActionUpdated = 11
    case customActionRemoved = 12
}

/// Privacy-safe delivery route stored in feedback outcome events.
public enum DiagnosticFeedbackRoute: Int, Sendable, Codable, CaseIterable {
    case privilegedAgent = 1
    case email = 2
    case privilegedAgentFallbackToEmail = 3
}

/// Privacy-safe visual style stored for toast admission events. Toast title,
/// message, action label, and coalescing key are never retained.
public enum DiagnosticToastStyle: Int, Sendable, Codable, CaseIterable {
    case info = 1
    case success = 2
    case warning = 3
    case failure = 4
}

/// Fixed reason stored in ``DiagnosticAppEventKind/toastDismissed``.
public enum DiagnosticToastDismissReason: Int, Sendable, Codable, CaseIterable {
    case caller = 1
    case automatic = 2
    case featureDisabled = 3
    case dismissAll = 4
    case removedFromQueue = 5
}

/// A typed, privacy-safe value carried by an app diagnostic event.
///
/// The durable event schema stores this discriminator in `DiagnosticEvent.c`,
/// but producers use this enum instead of the generic `count` parameter. That
/// keeps item counts, byte counts, and categorical values distinct at the API
/// boundary and lets report presentation assign a stable semantic field name.
public enum DiagnosticAppEventDetail: Sendable, Equatable {
    case terminalToolbarAction(DiagnosticTerminalToolbarAction)
    case terminalZoomAction(DiagnosticTerminalZoomAction)
    case primaryTab(DiagnosticPrimaryTab)
    case searchScope(DiagnosticSearchScope)
    case toolbarConfigurationAction(DiagnosticToolbarConfigurationAction)
    case feedbackRoute(DiagnosticFeedbackRoute)
    case toastStyle(DiagnosticToastStyle)
    case toastDismissReason(DiagnosticToastDismissReason)

    var rawValue: Int {
        switch self {
        case .terminalToolbarAction(let value): value.rawValue
        case .terminalZoomAction(let value): value.rawValue
        case .primaryTab(let value): value.rawValue
        case .searchScope(let value): value.rawValue
        case .toolbarConfigurationAction(let value): value.rawValue
        case .feedbackRoute(let value): value.rawValue
        case .toastStyle(let value): value.rawValue
        case .toastDismissReason(let value): value.rawValue
        }
    }

    func supports(_ kind: DiagnosticAppEventKind) -> Bool {
        switch (self, kind) {
        case (.terminalToolbarAction(_), .terminalToolbarActionUsed),
             (.terminalZoomAction(_), .terminalZoomChanged),
             (.primaryTab(_), .primaryTabSelected),
             (.searchScope(_), .searchPresented),
             (.searchScope(_), .searchDismissed),
             (.searchScope(_), .searchResultSelected),
             (.toolbarConfigurationAction(_), .customToolbarChanged),
             (.toolbarConfigurationAction(_), .terminalShortcutChanged),
             (.feedbackRoute(_), .feedbackSubmitStarted),
             (.feedbackRoute(_), .feedbackSubmitSucceeded),
             (.feedbackRoute(_), .feedbackSubmitFailed),
             (.toastStyle(_), .toastPresented),
             (.toastStyle(_), .toastCoalesced),
             (.toastStyle(_), .toastQueued),
             (.toastStyle(_), .toastDropped),
             (.toastDismissReason(_), .toastDismissed):
            true
        default:
            false
        }
    }
}
