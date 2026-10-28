public import Foundation

// A web pane's calls and console lines, and approved App Store bundles
// (plans/cmux-next/custom-panes-DESIGN.md sections 3 and 6.4). The supervisor
// decides every call; nothing here grants anything.
extension AppsClient {
    /// One `cmux.call(op, params)` of `app`'s web pane: the supervisor's ok body
    /// (`{value, revision?, ...}`), or its refusal.
    public func webCall(app: String, op: String, params: AppJSON) async throws(AppsClientError) -> AppJSON {
        if case .unavailable(let reason) = availability { throw .unavailable(reason) }
        do throws(AppsTransportError) {
            return try await transport.webCall(app: app, op: op, args: params)
        } catch {
            throw .refused(error)
        }
    }

    /// One console line of `app`'s web pane into its log ring. Best effort: a line
    /// that cannot be sent (no supervisor) is dropped.
    public func webLog(app: String, level: String, message: String) {
        guard availability.isAvailable else { return }
        let transport = transport
        let previous = webLogTail
        // task-owner: the client's log chain (webLogTail); one send per line, in order; the pane caps lines per load
        webLogTail = Task {
            await previous?.value
            try? await transport.webLog(app: app, level: level, message: message)
        }
    }

    /// Hands an approved bundle to the supervisor, which checks it against
    /// `sha256` and adds it to its catalog.
    public func registryPut(app: String, version: String, sha256: String, files: [String: String]) async throws(AppsClientError) {
        if case .unavailable(let reason) = availability { throw .unavailable(reason) }
        do throws(AppsTransportError) {
            try await transport.registryPut(app: app, version: version, sha256: sha256, files: files)
        } catch {
            throw .refused(error)
        }
        refresh()
    }

    /// The local `app` packed for the App Store's review queue under `publisher`, read off
    /// the main thread.
    public func registrySubmission(app: String, publisher: String) async throws(AppRegistrySubmission.Failure) -> AppRegistrySubmission {
        guard let bundle = bundleDirectory(for: app) else { throw AppRegistrySubmission.Failure("the app has no folder") }
        return try await Self.pack(bundle: bundle, app: app, publisher: publisher)
    }

    @concurrent nonisolated private static func pack(bundle: URL, app: String, publisher: String) async throws(AppRegistrySubmission.Failure)
        -> AppRegistrySubmission {
        // concurrency-allow: @concurrent, so the package walk never runs on the main actor
        try AppRegistrySubmission(bundle: bundle, localID: app, publisher: publisher)
    }
}
