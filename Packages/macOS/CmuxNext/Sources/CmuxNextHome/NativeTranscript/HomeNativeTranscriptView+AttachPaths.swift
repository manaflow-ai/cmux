public import AppKit

/// Which user entry point an attach by path stands in for.
public enum HomeAttachVia: String, CaseIterable, Sendable {
    case drop, paste, pick
}

/// What an attach by path did.
public enum HomeAttachResult: String, Sendable {
    /// The files entered the composer's intake (refusals show as its notice).
    case accepted
    /// A path names no file.
    case missingFile
    /// This composer has no data side (`connect(_:)` was not called).
    case notConnected
}

/// Attaching files by path for automation (the DEBUG socket verb
/// `debug.home.attach` and the `home.attachFiles` action): the files take
/// the very path a drop, a paste or the file picker takes, so a preflight
/// proves the user's path.
extension HomeNativeTranscriptView {
    /// The composer has a data side and takes attachments.
    public var canAttach: Bool { attachmentPreparer != nil }

    public func attachFiles(paths: [String], via: HomeAttachVia) -> HomeAttachResult {
        guard attachmentPreparer != nil else { return .notConnected }
        let urls = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        // A stat per path, only for automation: no bytes are read here.
        guard !urls.isEmpty, urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { return .missingFile }
        switch via {
        case .drop: _ = handleDrop(HomePasteboardValue(fileURLs: urls))
        case .paste: _ = handlePaste(HomePasteboardValue(fileURLs: urls))
        case .pick: handlePicked(urls)
        }
        return .accepted
    }
}

/// Pasteboard contents as a value: files given by path take the drop and
/// paste intake without writing the user's pasteboard.
struct HomePasteboardValue: HomePasteboardContents {
    var fileURLs: [URL]

    func hasType(_ types: [NSPasteboard.PasteboardType]) -> Bool { types.contains(.fileURL) && !fileURLs.isEmpty }
    func data(forType type: NSPasteboard.PasteboardType) -> Data? { nil }
    func string(forType type: NSPasteboard.PasteboardType) -> String? { nil }
}

extension HomeNativeTranscriptView {
    /// The Home transcript a window shows: the one holding the keyboard,
    /// else the first visible one (a Home tab whose box is not focused).
    public static func shown(in window: NSWindow?) -> HomeNativeTranscriptView? {
        guard let window else { return nil }
        var responder = window.firstResponder as? NSView
        while let view = responder {
            if let home = view as? HomeNativeTranscriptView { return home }
            responder = view.superview
        }
        var stack = [window.contentView].compactMap { $0 }
        while let view = stack.popLast() {
            if let home = view as? HomeNativeTranscriptView, !home.isHiddenOrHasHiddenAncestor { return home }
            stack.append(contentsOf: view.subviews.reversed())
        }
        return nil
    }
}

/// Automation (the DEBUG socket verb `debug.home.drive`): the same entry
/// points a user reaches, for screenshots and recordings.
extension HomeNativeTranscriptView {
    /// Return in the field: sends the text and the draft attachments.
    /// Nil when the draft went (or waits for the owner as "sending"), else why nothing was sent.
    @discardableResult
    public func sendDraft() -> String? { transcript.sendDraft() }
    /// A love tapback on the newest incoming message (the picker's path).
    public func debugTapbackNewestIncoming(mine: Bool = false) -> Bool { transcript.debugTapbackNewestIncoming(mine: mine) }
    /// Plays or pauses the newest video bubble (the click's path).
    public func debugToggleNewestVideo() -> Bool { transcript.debugToggleNewestVideo() }
    /// The context menu's titles at the newest text bubble (the right-click's path).
    public func debugMenuTitles(mine: Bool) -> [String]? { transcript.debugMenuTitles(mine: mine) }
    /// The field's height and the gap under the newest receipt, in points.
    /// With the drop target's state: the draft's attachment count, drops on their way, the highlight (1 shown).
    public func debugGeometry() -> [String: Double] {
        transcript.debugGeometry().merging(["draftAttachments": Double(transcript.draftAttachments.count), "dropPending": Double(drop.pending),
                                            "dropHighlighted": drop.highlight.isShowing ? 1 : 0]) { $1 }
    }
    /// Clicks the first shown link whose URL starts with `prefix` (the click's path); its URL.
    public func debugClickLink(prefix: String) -> String? { transcript.debugClickLink(prefix: prefix) }
    /// Moves the transcript by `dx`, `dy` points in this view (a pane on a fraction of a point).
    public func debugNudge(dx: CGFloat, dy: CGFloat) {
        debugTranscriptOffset = CGPoint(x: debugTranscriptOffset.x + dx, y: debugTranscriptOffset.y + dy)
        layoutSubtreeIfNeeded()
    }
    /// Narrows the transcript to `trim` points under this view's width and lays it out now, in this
    /// main-thread turn (no display frame passes between two calls in one socket request).
    public func debugTrimWidth(_ trim: CGFloat) {
        debugTranscriptWidthTrim = trim
        layoutSubtreeIfNeeded()
    }
    /// MessagesLab's width pass counters (all panes): passes run, passes deferred to the next frame.
    public var debugWidthPasses: (passes: Int, deferred: Int) { transcript.debugWidthPasses }
    /// MessagesLab's width pass frame budget (s).
    public var debugWidthPassBudget: Double { transcript.debugWidthPassBudget }
    /// The transcript host's origin in window points (bottom-left origin).
    public var debugHostOrigin: CGPoint { transcript.debugHostOrigin }
    /// The transcript host's frame in window points (bottom-left origin).
    public var debugHostFrame: CGRect { transcript.debugHostFrame }
    /// The typing bubble's body in window coordinates (bottom-left origin), nil when none shows.
    public func debugTypingBubbleFrame() -> CGRect? { transcript.debugTypingBubbleFrame() }
    /// The visible rows as drawn (a part: its bubble body and drawn balloon; a preview or other row: its content box),
    /// window coordinates (bottom-left origin), top to bottom.
    public func debugRowFrames() -> [(kind: String, key: String, outgoing: Bool, frame: CGRect, balloon: CGRect)] { transcript.debugRowFrames() }
    /// The text of the newest `limit` messages this view shows, oldest first.
    public func debugMessageTexts(limit: Int = 10) -> [String] { transcript.debugMessageTexts(limit: limit) }
    public var debugStatusLine: String? { transcript.debugStatusLine }
    public var debugRebuilds: Int { transcript.debugRebuilds }
    public var debugStreamTexts: [String] { transcript.debugStreamTexts }
    public var debugLineCloseAfterHandOffFires: Int? { transcript.debugLineCloseAfterHandOffFires }
    /// Clicks the newest thread's "N Replies" or preview (the click's path); the open thread's root.
    public func debugOpenNewestThread() -> String? { transcript.debugOpenNewestThread() }
    /// The open thread's root (the transcript's id), nil when none is open.
    public var debugOpenThread: String? { transcript.debugOpenThread }
    /// Esc through the field's path.
    public func debugEscape() { transcript.debugEscape() }
    /// Reply… in the newest text bubble's context menu; the open thread's root.
    public func debugReplyNewest(mine: Bool) -> String? { transcript.debugReplyNewest(mine: mine) }
    /// A real Esc key press through the app's event queue (`outside`: the key focus leaves the pane first).
    public func debugPostEscape(outside: Bool) { transcript.debugPostEscape(outside: outside) }
    /// Scrolls the transcript by `dy` points through AppKit's scroll view.
    public func debugScroll(by dy: CGFloat) { transcript.debugScroll(by: dy) }
}
