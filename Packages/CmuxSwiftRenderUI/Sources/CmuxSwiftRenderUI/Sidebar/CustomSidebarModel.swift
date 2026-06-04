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
    private var fileURL: URL
    private let directoryURL: URL
    private let sidebarName: String
    private let fileManager: FileManager

    private var reloadObserver: NSObjectProtocol?

    private let interpreter = SwiftViewInterpreter()
    // Cache the parsed Swift program so re-rendering against live data (the
    // host re-evaluates each `TimelineView` tick) does not re-parse unchanged
    // source. Keyed by the source string; `reload()` swaps in new source on
    // file change, which invalidates the cache on the next `renderNode` call.
    private var cachedSource: String?
    private var cachedProgram: ParsedProgram?

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        directoryURL = fileURL.deletingLastPathComponent()
        sidebarName = fileURL.deletingPathExtension().lastPathComponent
        self.fileManager = fileManager
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
        guard reloadObserver == nil else { return }
        reloadObserver = NotificationCenter.default.addObserver(
            forName: .customSidebarReloadRequested,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let names = notification.userInfo?["names"] as? [String]
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.matchesReloadRequest(names: names) else { return }
                self.reload()
            }
        }
    }

    func stop() {
        if let reloadObserver {
            NotificationCenter.default.removeObserver(reloadObserver)
            self.reloadObserver = nil
        }
    }

    /// Re-reads the file: stores `.swift` source verbatim, decodes `.json`.
    func reload() {
        fileURL = preferredFileURL()
        guard fileManager.fileExists(atPath: fileURL.path) else {
            state = .missing
            return
        }
        if fileURL.pathExtension.lowercased() == "swift" {
            do {
                state = .swiftSource(try String(contentsOf: fileURL, encoding: .utf8))
            } catch {
                state = .failed(CustomSidebarValidator().describe(error))
            }
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let document = try JSONDecoder().decode(DSLDocument.self, from: data)
            state = .json(document)
        } catch {
            state = .failed(CustomSidebarValidator().describe(error))
        }
    }

    private func matchesReloadRequest(names: [String]?) -> Bool {
        guard let names, !names.isEmpty else {
            return true
        }
        return names.contains(sidebarName)
    }

    private func preferredFileURL() -> URL {
        let swiftURL = directoryURL.appendingPathComponent("\(sidebarName).swift")
        if fileManager.fileExists(atPath: swiftURL.path) {
            return swiftURL
        }

        let jsonURL = directoryURL.appendingPathComponent("\(sidebarName).json")
        if fileManager.fileExists(atPath: jsonURL.path) {
            return jsonURL
        }

        return fileURL
    }
}
