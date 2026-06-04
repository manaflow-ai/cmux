import CmuxSettings
import CmuxSwiftRender
import Foundation

/// Loads a named custom sidebar file and reloads it on explicit request.
///
/// The file is either an interpreted `.swift` view or a declarative `.json`
/// document. The model stores raw Swift source so the view can re-interpret it
/// against the live data context without re-reading the file on every render.
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

    private var reloadTask: Task<Void, Never>?

    private let interpreter = SwiftViewInterpreter()
    // Cache the parsed Swift program so re-rendering against live data (the
    // host re-evaluates each `TimelineView` tick) does not re-parse unchanged
    // source. Keyed by the source string; `reload()` swaps in new source on
    // file change, which invalidates the cache on the next `renderNode` call.
    private var cachedSource: String?
    private var cachedProgram: ParsedProgram?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Interprets the current Swift source against `dataContext`, reusing a
    /// cached parse so the expensive AST parse/fold runs only when the source
    /// changes (not on every render).
    ///
    /// Returns `nil` when the current state is not `.swiftSource` or the source
    /// produces no supported view. The view layer maps `nil` to its error UI.
    func renderNode(dataContext: [String: SwiftValue]) -> RenderNode? {
        guard case let .swiftSource(source) = state else { return nil }
        let program: ParsedProgram
        if cachedSource == source, let cached = cachedProgram {
            program = cached
        } else {
            program = interpreter.parse(source)
            cachedSource = source
            cachedProgram = program
        }
        return interpreter.evaluate(program, state: dataContext)
    }

    /// Loads the file once and listens for explicit reload requests.
    /// Idempotent.
    func start() {
        reload()
        guard reloadTask == nil else { return }
        reloadTask = Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(named: .customSidebarReloadRequested) {
                guard let self else { return }
                guard self.matchesReloadRequest(notification) else { continue }
                self.reload()
            }
        }
    }

    func stop() {
        reloadTask?.cancel()
        reloadTask = nil
    }

    /// Re-reads the file: stores `.swift` source verbatim, decodes `.json`.
    func reload() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            state = .missing
            return
        }
        if fileURL.pathExtension.lowercased() == "swift" {
            do {
                state = .swiftSource(try String(contentsOf: fileURL, encoding: .utf8))
            } catch {
                state = .failed(CustomSidebarValidation.describe(error))
            }
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let document = try JSONDecoder().decode(DSLDocument.self, from: data)
            state = .json(document)
        } catch {
            state = .failed(CustomSidebarValidation.describe(error))
        }
    }

    private func matchesReloadRequest(_ notification: Notification) -> Bool {
        guard let names = notification.userInfo?["names"] as? [String], !names.isEmpty else {
            return true
        }
        let name = fileURL.deletingPathExtension().lastPathComponent
        return names.contains(name)
    }
}
