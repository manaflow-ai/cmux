public import AppKit
public import Foundation
public import Observation

/// Where a page-requested tab should open.
public nonisolated enum BrowserNewTabDisposition: Hashable, Sendable {
    /// A new selected tab next to the opener (plain `target=_blank`).
    case foregroundTab
    /// A new unselected tab (Cmd-click, middle click).
    case backgroundTab
    /// `window.open` with window features (OAuth, payment popups). Callers may
    /// show it as a tab or a small floating pane; it keeps `window.opener`.
    case popup
}

/// Requests a tab sends to its host. The App layer turns them into daemon
/// commands (create tab, close tab) or UI (downloads list).
public enum BrowserTabIntent {
    /// Open `url` in a new tab. No opener relationship.
    case openURL(URL, BrowserNewTabDisposition)
    /// Insert an already-created tab. Used when the page needs the returned
    /// window object (`window.opener`), so the engine must create the tab
    /// synchronously. The host must insert or close it.
    case adoptTab(any BrowserTab, BrowserNewTabDisposition)
    /// The page called `window.close()`.
    case close
    /// A download started. Observe the object for progress.
    case download(BrowserDownload)
}

/// Receives intents from a tab.
public protocol BrowserTabDelegate: AnyObject {
    func browserTab(_ tab: any BrowserTab, didRequest intent: BrowserTabIntent)
}

/// What the host did with a key equivalent.
public nonisolated enum BrowserKeyDisposition: Hashable, Sendable {
    /// Let the page (and then the engine's default handling) see it.
    case passToPage
    /// The host consumed it (app shortcut such as new tab, palette).
    case handledByHost
}

/// Hook that runs before the page sees a key equivalent, so app shortcuts
/// win over page handlers. CEF implements it from its pre-key-event handler.
public protocol BrowserKeyRouting: AnyObject {
    func browserTab(_ tab: any BrowserTab, keyEquivalent event: NSEvent) -> BrowserKeyDisposition
}

// MARK: - Prompts

/// A capability a page asked for.
public nonisolated enum BrowserPermissionKind: Hashable, Sendable {
    case camera
    case microphone
    case cameraAndMicrophone
}

/// What a prompt asks the user.
public nonisolated enum BrowserPromptKind: Hashable, Sendable {
    case permission(BrowserPermissionKind)
    case alert(message: String)
    case confirm(message: String)
    case textInput(message: String, defaultText: String?)
}

/// The user's answer to a prompt.
public nonisolated enum BrowserPromptResponse: Hashable, Sendable {
    case allow
    case deny
    /// Alert or confirm accepted.
    case accept
    /// Confirm or text input cancelled.
    case cancel
    case text(String)
}

/// A pending question from a page: a permission request or a JavaScript
/// dialog. The chrome shows the first pending prompt of the selected tab.
/// A prompt is answered exactly once; closing the tab denies every pending one.
public final class BrowserPrompt: Identifiable {
    public let id = UUID()
    public let kind: BrowserPromptKind
    /// Origin shown to the user ("https://meet.example.com").
    public let origin: String
    private var completion: ((BrowserPromptResponse) -> Void)?

    public init(kind: BrowserPromptKind, origin: String, completion: @escaping (BrowserPromptResponse) -> Void) {
        self.kind = kind
        self.origin = origin
        self.completion = completion
    }

    public var isResolved: Bool { completion == nil }

    /// Answers the prompt. Later calls are ignored.
    public func respond(_ response: BrowserPromptResponse) {
        guard let completion else { return }
        self.completion = nil
        completion(response)
    }

    /// The response used when the prompt is dismissed without an answer.
    public var dismissalResponse: BrowserPromptResponse {
        switch kind {
        case .permission: .deny
        case .alert: .accept
        case .confirm, .textInput: .cancel
        }
    }
}

// MARK: - Downloads

/// A download in progress or completed.
@Observable
public final class BrowserDownload: Identifiable {
    public enum Status: Hashable, Sendable {
        case inProgress
        case finished
        case failed(String)
        case cancelled
    }

    public let id = UUID()
    public let sourceURL: URL?
    public internal(set) var filename: String
    public internal(set) var destination: URL?
    /// `0...1`, or nil when the size is unknown.
    public internal(set) var fraction: Double?
    public internal(set) var status: Status = .inProgress

    @ObservationIgnored
    var cancelHandler: (() -> Void)?

    public init(sourceURL: URL?, filename: String) {
        self.sourceURL = sourceURL
        self.filename = filename
    }

    public func cancel() {
        guard status == .inProgress else { return }
        cancelHandler?()
        status = .cancelled
    }
}

// MARK: - Find and snapshots

public nonisolated enum BrowserFindDirection: Hashable, Sendable {
    case forward
    case backward
}

/// Result of a find-in-page step.
public nonisolated struct BrowserFindResult: Hashable, Sendable {
    public var matchFound: Bool
    /// Total matches when the engine can count them.
    public var matchCount: Int?
    /// 1-based index of the highlighted match when known.
    public var currentIndex: Int?

    public init(matchFound: Bool, matchCount: Int? = nil, currentIndex: Int? = nil) {
        self.matchFound = matchFound
        self.matchCount = matchCount
        self.currentIndex = currentIndex
    }

    public static let none = BrowserFindResult(matchFound: false, matchCount: 0)
}

/// JavaScript world for `evaluate`.
public nonisolated enum BrowserScriptWorld: Hashable, Sendable {
    /// The page's own world: sees page globals.
    case page
    /// An isolated world: shares the DOM but not page globals. Use for
    /// automation so pages cannot tamper with the scripts.
    case isolated
}

public nonisolated enum BrowserTabError: Error, Hashable, Sendable {
    case closed
    case snapshotUnavailable
    case javaScript(String)
    case unsupported(String)
}
