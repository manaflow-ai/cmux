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
