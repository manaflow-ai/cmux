import Observation
import CmuxFoundation
import CmuxSettings
import CmuxSwiftRender
import Foundation

/// Loads a named custom sidebar file, hot-reloads it on change, and reloads it
/// on explicit request.
///
/// The file is either an interpreted `.swift` view or a declarative `.json`
/// document, resolved by name (`.swift` preferred when both exist). Reload
/// triggers:
/// - the file changing on disk, via ``CmuxFileWatch/FileWatcher``
///   (kqueue-backed) — safe to act on because rendering is last-good sticky
///   (a broken mid-edit save never replaces a working sidebar; see
///   ``renderSwift(dataContext:)`` and the remote worker's refresh);
/// - an explicit `customSidebarReloadRequested` notification (posted for the
///   CLI's `sidebar reload`), optionally filtered by sidebar name.
@MainActor
@Observable
public final class CustomSidebarModel {
    /// The loaded state of the sidebar file.
    public enum State: Equatable, Sendable {
        /// The file does not exist (or is empty).
        case missing
        /// A declarative JSON sidebar document.
        case json(DSLDocument)
        /// Raw interpreted-Swift sidebar source.
        case swiftSource(String)
        /// The file exists but could not be loaded/decoded.
        case failed(String)
    }

    /// The current loaded state of the watched file.
    public private(set) var state: State = .missing
    /// The currently resolved sidebar file (extension can flip between
    /// `.swift`/`.json` across reloads when both exist by name).
    public private(set) var fileURL: URL
    private let directoryURL: URL
    private let sidebarName: String
    private let fileManager: FileManager

    private var watchTask: Task<Void, Never>?
    private var watcher: FileWatcher?
    private var reloadObserver: NSObjectProtocol?

    /// The interpreter the source is rendered through. Defaults to the
    /// in-process implementation; the app injects an out-of-process,
    /// crash-isolating ``SidebarInterpreting`` so an interpreter fault from an
    /// untrusted sidebar can't take down the host.
    private let interpreter: any SidebarInterpreting

    /// Latest interpreted view for `.swiftSource`, updated only when a render
    /// completes so live re-renders don't flash empty between ticks.
    public private(set) var swiftRender: RenderNode?
    /// True once the first `.swiftSource` render completes, letting the view
    /// distinguish "still rendering" from "rendered, no view" (error state).
    public private(set) var hasRenderedSwift = false
    /// Bumps when the loaded source changes, so the view's render trigger
    /// re-fires on file reload even when the data context is unchanged.
    public private(set) var sourceRevision = 0

    /// Creates a model for `fileURL` rendering through `interpreter`.
    public init(
        fileURL: URL,
        interpreter: any SidebarInterpreting = InProcessSidebarInterpreter(),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        directoryURL = fileURL.deletingLastPathComponent()
        sidebarName = fileURL.deletingPathExtension().lastPathComponent
        self.interpreter = interpreter
        self.fileManager = fileManager
    }

    /// Interprets the current `.swiftSource` against `dataContext` through the
    /// injected interpreter and publishes the result. No-op for other states.
    ///
    /// Drive this from the view's `.task(id:)` so it re-runs on each data-
    /// context change and on source reload; cancellation (a newer trigger
    /// superseding this one) discards the stale result instead of publishing it.
    public func renderSwift(dataContext: [String: SwiftValue]) async {
        guard case let .swiftSource(source) = state else { return }
        let node = await interpreter.render(source: source, state: dataContext)
        if Task.isCancelled { return }
        // Last-good sticky: a broken mid-edit save (nil node) keeps the
        // previous working render instead of flashing the error state; the
        // error still shows when there was never a good render.
        if node != nil || swiftRender == nil {
            swiftRender = node
        }
        hasRenderedSwift = true
    }

    /// Loads the file once, starts watching it, and listens for explicit
    /// reload requests. Idempotent.
    public func start() {
        reload()
        startWatcher()
        if reloadObserver == nil {
            reloadObserver = NotificationCenter.default.addObserver(
                forName: .customSidebarReloadRequested,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let names = notification.userInfo?["names"] as? [String]
                Task { @MainActor [weak self] in
                    self?.requestReload(names: names)
                }
            }
        }
    }

    /// Stops watching the file and listening for reloads. Safe to call
    /// repeatedly.
    public func stop() {
        stopWatcher()
        if let reloadObserver {
            NotificationCenter.default.removeObserver(reloadObserver)
            self.reloadObserver = nil
        }
    }

    /// Reloads when `names` is empty/absent or contains this sidebar's name.
    /// The explicit-reload entry point shared by the in-process notification
    /// path and the out-of-process worker (which receives forwarded reload
    /// requests over its channel; host notifications don't cross processes).
    public func requestReload(names: [String]?) {
        if let names, !names.isEmpty, !names.contains(sidebarName) { return }
        reload()
    }

    /// (Re)arms the kqueue watcher on the currently resolved file. Reload can
    /// flip the resolved extension (`name.swift` <-> `name.json`); the watcher
    /// must follow or hot reload silently stops after a flip.
    private var watchedPath: String?

    private func startWatcher() {
        let path = fileURL.path
        guard watchedPath != path else { return }
        stopWatcher()
        watchedPath = path
        // Leading-edge throttle coalesces the burst of kqueue events an
        // atomic save emits into one reload.
        let watcher = FileWatcher(path: path, throttle: .milliseconds(150))
        self.watcher = watcher
        watchTask = Task { [weak self] in
            for await _ in watcher.events {
                guard let self else { return }
                self.reload()
            }
        }
    }

    private func stopWatcher() {
        watchTask?.cancel()
        watchTask = nil
        watchedPath = nil
        if let watcher {
            self.watcher = nil
            Task { await watcher.stop() }
        }
    }

    /// Re-reads the file: stores `.swift` source verbatim, decodes `.json`.
    public func reload() {
        defer {
            sourceRevision += 1 // re-fire the view's render trigger
            // Follow extension flips with the watcher; no-op when unchanged.
            if watchTask != nil || watchedPath != nil { startWatcher() }
        }
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
