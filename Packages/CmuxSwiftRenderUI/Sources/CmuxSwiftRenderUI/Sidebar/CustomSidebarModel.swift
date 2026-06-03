import CmuxFileWatch
import CmuxSettings
import CmuxSwiftRender
import Foundation

/// Loads a named custom sidebar file and hot-reloads it on change.
///
/// The file is either an interpreted `.swift` view or a declarative `.json`
/// document. Watched via ``CmuxFileWatch/FileWatcher`` (kqueue-backed); the
/// model stores raw Swift source so the view can re-interpret it against the
/// live data context, not only on file save.
@MainActor
@Observable
final class CustomSidebarModel {
    /// The loaded state of the sidebar file.
    enum State: Equatable {
        case missing
        case json(DSLDocument)
        case swiftSource(String)
        case failed(String)
    }

    private(set) var state: State = .missing
    let fileURL: URL

    private var watchTask: Task<Void, Never>?
    private var watcher: FileWatcher?

    /// The interpreter the source is rendered through. Defaults to the
    /// in-process implementation; the app injects an out-of-process,
    /// crash-isolating ``SidebarInterpreting`` so an interpreter fault from an
    /// untrusted sidebar can't take down the host.
    private let interpreter: any SidebarInterpreting

    /// Latest interpreted view for `.swiftSource`, updated only when a render
    /// completes so live re-renders don't flash empty between ticks.
    private(set) var swiftRender: RenderNode?
    /// True once the first `.swiftSource` render completes, letting the view
    /// distinguish "still rendering" from "rendered, no view" (error state).
    private(set) var hasRenderedSwift = false
    /// Bumps when the loaded source changes, so the view's render trigger
    /// re-fires on file reload even when the data context is unchanged.
    private(set) var sourceRevision = 0

    init(fileURL: URL, interpreter: any SidebarInterpreting = InProcessSidebarInterpreter()) {
        self.fileURL = fileURL
        self.interpreter = interpreter
    }

    /// Interprets the current `.swiftSource` against `dataContext` through the
    /// injected interpreter and publishes the result. No-op for other states.
    ///
    /// Drive this from the view's `.task(id:)` so it re-runs on each data-
    /// context change and on source reload; cancellation (a newer trigger
    /// superseding this one) discards the stale result instead of publishing it.
    func renderSwift(dataContext: [String: SwiftValue]) async {
        guard case let .swiftSource(source) = state else { return }
        let node = await interpreter.render(source: source, state: dataContext)
        if Task.isCancelled { return }
        swiftRender = node
        hasRenderedSwift = true
    }

    /// Loads the file once and starts watching it. Idempotent.
    func start() {
        reload()
        guard watchTask == nil else { return }
        // Leading-edge throttle coalesces the burst of kqueue events an atomic
        // save emits into one reload.
        let watcher = FileWatcher(path: fileURL.path, throttle: .milliseconds(150))
        self.watcher = watcher
        watchTask = Task { [weak self] in
            for await _ in watcher.events {
                guard let self else { return }
                self.reload()
            }
        }
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
        if let watcher {
            self.watcher = nil
            Task { await watcher.stop() }
        }
    }

    /// Re-reads the file: stores `.swift` source verbatim, decodes `.json`.
    func reload() {
        defer { sourceRevision += 1 } // re-fire the view's render trigger
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            state = .missing
            return
        }
        if fileURL.pathExtension.lowercased() == "swift" {
            do {
                state = .swiftSource(try String(contentsOf: fileURL, encoding: .utf8))
            } catch {
                state = .failed(Self.describe(error))
            }
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let document = try JSONDecoder().decode(DSLDocument.self, from: data)
            state = .json(document)
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    private static func describe(_ error: Error) -> String {
        if let decoding = error as? DecodingError {
            switch decoding {
            case let .keyNotFound(key, ctx):
                return "Missing key '\(key.stringValue)' at \(path(ctx))"
            case let .typeMismatch(_, ctx):
                return "Type mismatch at \(path(ctx)): \(ctx.debugDescription)"
            case let .valueNotFound(_, ctx):
                return "Missing value at \(path(ctx))"
            case let .dataCorrupted(ctx):
                return "Invalid JSON at \(path(ctx)): \(ctx.debugDescription)"
            @unknown default:
                return decoding.localizedDescription
            }
        }
        return (error as NSError).localizedDescription
    }

    private static func path(_ ctx: DecodingError.Context) -> String {
        let parts = ctx.codingPath.map(\.stringValue)
        return parts.isEmpty ? "root" : parts.joined(separator: " › ")
    }
}
