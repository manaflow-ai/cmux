import CmuxNextCompat
import Darwin
import Foundation

/// Turns a tab's renderer end and main-frame load failure into a
/// ``BrowserEngineFailure`` with the running engine's versions, for the App
/// (crash reporting). The App sets ``onFailure``; until then this does
/// nothing. The renderer ends of a closed tab and of quit are not failures.
///
/// The versions come from the loaded framework's `cef_version_info`, looked
/// up once off the main thread (`dlopen` holds dyld's lock); failures that
/// come before that wait for it, at most ``maxWaiting`` of them.
@MainActor
final class CEFFailureReports {
    /// The most failures kept while the versions are read.
    static let maxWaiting = 32
    /// Receives each failure (cancelled loads included: the receiver filters).
    var onFailure: ((BrowserEngineFailure) -> Void)?
    private var versions: BrowserEngineVersions?
    private var waiting: [BrowserEngineFailure] = []
    private var readingVersions = false

    /// After `tab` handled `event`: a renderer end or a load error becomes a failure.
    func note(_ event: CEFShimEvent, tab: CEFTab) {
        guard onFailure != nil, !tab.isClosed, tab.runtime.shutdownSequence == nil else { return }
        switch event {
        case .renderTerminated(_, let status, let code, let text):
            send(.rendererTerminated(status: status, code: code, text: text, url: tab.committedURL ?? tab.state.url), runtime: tab.runtime)
        case .loadError(_, let code, let text, let url, let interstitial):
            send(.loadFailed(code: code, name: text, url: URL(string: url), interstitial: interstitial), runtime: tab.runtime)
        default:
            break
        }
    }

    private func send(_ failure: BrowserEngineFailure, runtime: CEFRuntime) {
        if let versions {
            var failure = failure
            failure.versions = versions
            onFailure?(failure)
            return
        }
        if waiting.count < Self.maxWaiting { waiting.append(failure) }
        guard !readingVersions else { return }
        readingVersions = true
        let binary = runtime.layout?.frameworkBinary.path
        let fork = runtime.shim.map { Int($0.forkAPIVersion()) }
        // task-owner: one lookup per process; it delivers the failures that waited for it.
        Task { [weak self] in
            let read = await Task.detached(priority: .utility) { Self.readVersions(frameworkBinary: binary, forkAPI: fork) }.value
            self?.versionsRead(read)
        }
    }

    private func versionsRead(_ read: BrowserEngineVersions) {
        versions = read
        let failures = waiting
        waiting = []
        for failure in failures {
            var failure = failure
            failure.versions = read
            onFailure?(failure)
        }
    }

    /// `cef_version_info` of the framework the shim loaded, and the fork's API
    /// version. Off the main thread only.
    nonisolated static func readVersions(frameworkBinary: String?, forkAPI: Int?) -> BrowserEngineVersions {
        let fork = forkAPI.flatMap { $0 > 0 ? $0 : nil }
        // concurrency-allow: called only from a detached utility task (`send`), never the main thread.
        guard let frameworkBinary, let handle = dlopen(frameworkBinary, RTLD_NOLOAD | RTLD_LAZY) else {
            return BrowserEngineVersions(forkAPI: fork)
        }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "cef_version_info") else { return BrowserEngineVersions(forkAPI: fork) }
        let info = unsafeBitCast(symbol, to: (@convention(c) (Int32) -> Int32).self)
        return .cef(info: { info($0) }, forkAPI: fork)
    }
}
