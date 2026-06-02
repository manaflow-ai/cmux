import CmuxSettings
import Foundation

/// Loads a named custom sidebar file and hot-reloads it on change.
///
/// The file is either an interpreted `.swift` view or a declarative `.json`
/// document. Watched via ``JSONConfigFileWatcher`` (kqueue-backed); the model
/// stores raw Swift source so the view can re-interpret it against the live
/// data context, not only on file save.
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

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Loads the file once and starts watching it. Idempotent.
    func start() {
        reload()
        guard watchTask == nil else { return }
        let url = fileURL
        watchTask = Task { [weak self] in
            let watcher = JSONConfigFileWatcher(fileURL: url)
            for await _ in watcher.events {
                guard let self else { return }
                self.reload()
            }
        }
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
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
