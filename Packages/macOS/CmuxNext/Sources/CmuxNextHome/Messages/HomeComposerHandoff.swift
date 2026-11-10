public import AppKit
public import CmuxNextDesign
public import CmuxNextPages
public import CmuxNextSettings
import CmuxNextCompat
import CmuxNextWakeups
import UniformTypeIdentifiers

/// A Messages page (the docked Home's, a conversation tab's, the Chief panel's) whose composer
/// takes what the app hands it.
@MainActor
public protocol HomeComposerHosting: NSView {
    var composerHandoff: HomeComposerHandoff { get }
}

/// The app's hand-off to the open conversation's composer on a Messages page (the native Home
/// composer's intake, moved to the page: webviews/src/pages/home-messages/composerHandoff.ts):
/// files by path (`home.attachFiles`, a viewer quote, a design mode card), which upload as a drop's
/// do, and the selected message text as a quote (`home.replyToSelection`). The page reads each file
/// from the host in chunks (``HomeComposerFiles``) and answers once it holds them all, so a caller
/// may delete files it wrote for the hand-off then. Nothing is sent.
@MainActor
public struct HomeComposerHandoff {
    /// Calls a page op and waits up to the duration for its answer; nil when it fails or never
    /// answers. The app builds it from its page-call deadline.
    public typealias Ask = @MainActor (_ op: String, _ params: [String: JSONValue], _ deadline: Duration) async -> JSONValue?

    private let ask: Ask
    private let files: HomeComposerFiles
    private let window: @MainActor () -> NSWindow?
    /// How long a hand-off waits for the page: every chunk of every file.
    public static let attachDeadline: Duration = .seconds(120)
    /// How long a quote or a take-back waits for the page.
    public static let answerDeadline: Duration = .seconds(5)

    public init(files: HomeComposerFiles, window: @escaping @MainActor () -> NSWindow?, ask: @escaping Ask) {
        self.files = files
        self.window = window
        self.ask = ask
    }

    /// The Messages page `window` shows: the one holding the keyboard, else the first visible one
    /// (a Home tab whose box is not focused). Nil: no Messages page there.
    public static func shown(in window: NSWindow?) -> HomeComposerHandoff? {
        HomeShownView.find(in: window) { ($0 as? any HomeComposerHosting)?.composerHandoff }
    }

    /// What a hand-off of files did.
    public enum AttachResult: Sendable, Equatable {
        /// The composer holds the files (refusals show as its notice).
        case accepted
        /// A path names no file.
        case missingFile
        /// The page shows no conversation whose owner takes files, or it did not answer.
        case notTaken
    }

    /// Hands `urls` to the composer, in order; `group` names them for ``remove(group:)``.
    public func attach(_ urls: [URL], group: String? = nil) async -> AttachResult {
        guard !urls.isEmpty, let listed = await Self.describe(urls) else { return .missingFile }
        let files = files
        let tokens = listed.map { files.stage($0.url) }
        defer { files.unstage(tokens) }
        let entries: [JSONValue] = zip(listed, tokens).map { file, token in
            .object(["token": .string(token), "name": .string(file.url.lastPathComponent), "mimeType": .string(file.mimeType),
                     "size": .number(Double(file.size))])
        }
        var params: [String: JSONValue] = ["files": .array(entries)]
        if let group { params["group"] = .string(group) }
        let answer = await call("home.messages.attach", params, within: Self.attachDeadline)
        return answer?.objectValue?["attached"]?.boolValue == true ? .accepted : .notTaken
    }

    /// Takes back the files ``attach(_:group:)`` added as `group` (their uploads stop).
    public func remove(group: String) async {
        _ = await call("home.messages.detach", ["group": .string(group)], within: Self.answerDeadline)
    }

    /// The text selected in one message becomes a quote in the composer; false: no such selection.
    public func quoteSelection() async -> Bool {
        await call("home.messages.quoteSelection", [:], within: Self.answerDeadline)?.objectValue?["quoted"]?.boolValue == true
    }

    /// Reply to Selection (Cmd-Shift-R, the palette): the words selected in one shown message open its
    /// reply with them quoted (pageCommands.ts `home.messages.replyToSelection`); false when none are.
    public func replyToSelection() async -> Bool {
        await call("home.messages.replyToSelection", [:], within: Self.answerDeadline)?.objectValue?["replied"]?.boolValue == true
    }

    /// The page's document is about to end (its tab or the Chief panel closed): it hands everything it
    /// holds alone to its owner first (`home.messages.settle`, settle.ts), up to ``settleDeadline``.
    public func settle() async {
        _ = await call("home.messages.settle", ["within": .number(5_000)], within: Self.settleDeadline)
    }

    /// How long a closing page may take to settle.
    public static let settleDeadline: Duration = .seconds(6)

    /// The file picker as a sheet on the page's window (the app's panel made ahead of the click,
    /// shared with an agent composer's attach); the chosen files go to the composer, and the person
    /// goes back to typing in the box. A window that already shows a sheet opens none.
    public func pickFiles(openPanel: MadeAheadOpenPanel) {
        guard let window = window(), window.attachedSheet == nil, let panel = openPanel.panel() else { return }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = HomeStrings.attachPrompt
        let handoff = self
        panel.beginSheetModal(for: window) { response in
            let urls = response == .OK ? panel.urls : []
            // task-owner: one hand-off of the picked files; ends with the page's answer (bounded by attachDeadline)
            // main-hop-allow: the sheet's completion runs on main; the task only awaits the page
            Task { @MainActor in
                if !urls.isEmpty { _ = await handoff.attach(urls) }
                _ = await handoff.call("home.messages.focusComposer", [:], within: Self.answerDeadline)
            }
        }
    }

    /// Calls `op` once the page answers at all (a page still loading has no handler yet: a cheap
    /// read is asked again, spaced by a backoff, for up to ``answerDeadline``), then waits for its
    /// answer up to `deadline`. Nil: the page never answered.
    func call(_ op: String, _ params: [String: JSONValue], within deadline: Duration) async -> JSONValue? {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: Self.answerDeadline)
        var backoff = Backoff(initial: .milliseconds(100), maximum: .seconds(1))
        while await ask("home.currentSelection", [:], .seconds(1)) == nil {
            guard clock.now < end, !Task.isCancelled else { return nil }
            // concurrency-allow: Backoff.wait suspends the task (no thread blocks); it spaces the asks of a page still loading
            do { try await backoff.wait(owner: "home.composer.handoff") } catch { return nil }
        }
        return await ask(op, params, deadline)
    }

    /// One file as the page lists it.
    struct Listed: Sendable {
        var url: URL
        var mimeType: String
        var size: UInt64
    }

    /// Each path's size and type, read off the main actor; nil when one names no regular file.
    @concurrent
    nonisolated static func describe(_ urls: [URL]) async -> [Listed]? {
        var listed: [Listed] = []
        for url in urls {
            let url = URL(fileURLWithPath: (url.path as NSString).expandingTildeInPath)
            let values = try? url.blockingResourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { return nil }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? ""
            listed.append(Listed(url: url, mimeType: mime, size: UInt64(max(0, values?.fileSize ?? 0))))
        }
        return listed
    }
}

/// `cmux.home.messages.compose.read {token, offset}` -> `{data: base64, size}`: a chunk of a file
/// the app handed a Messages page's composer (``HomeComposerHandoff``), by the token it staged. A
/// token reads only while its hand-off waits for the page.
@MainActor
public final class HomeComposerFiles: PageProvider {
    public static let prefix = "cmux.home.messages.compose."
    /// One chunk: a bounded frame across the page bridge, not a file cap.
    nonisolated static let maximumChunkBytes = 512 * 1024
    private var staged: [String: URL] = [:]

    public init() {}

    /// Lets the page read `url` under the returned token until ``unstage(_:)``.
    func stage(_ url: URL) -> String {
        let token = UUID().uuidString
        staged[token] = url
        return token
    }

    func unstage(_ tokens: [String]) {
        for token in tokens { staged[token] = nil }
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op == Self.prefix + "read" else { throw PageError.unknownOp(op) }
        guard let token = params["token"]?.stringValue, let url = staged[token] else {
            throw PageError.invalidParams("token must name a handed-over file")
        }
        let offset = UInt64(max(0, params["offset"]?.doubleValue ?? 0))
        guard let read = await Self.chunk(of: url, at: offset) else { throw PageError.unavailable("the file can no longer be read") }
        return .object(["data": .string(read.data.base64EncodedString()), "size": .number(Double(read.size))])
    }

    /// Up to ``maximumChunkBytes`` of `url` from `offset`, and the file's size now; read off the main actor.
    @concurrent
    nonisolated static func chunk(of url: URL, at offset: UInt64) async -> (data: Data, size: UInt64)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        guard offset < size else { return (Data(), size) }
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.blockingRead(upToCount: maximumChunkBytes) else { return nil }
        return (data, size)
    }
}
