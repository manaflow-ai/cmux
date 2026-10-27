/// Reads Chromium's EventLatency and ScrollJank histograms through the DevTools protocol
/// (`Browser.getHistograms`, content/browser/devtools/protocol/browser_handler.cc) on request only:
/// no timer and no polling, one call per query when `debug.input` reads or resets. Only the send runs on
/// the main actor (``Fetch``, the engine's DevTools call); the decode and the fold run on this actor.
///
/// Reset keeps the current histograms as a baseline that later reads subtract: the reader never asks
/// for `delta: true`, which marks Chromium's samples as logged (base/metrics/histogram_base.h
/// `SnapshotDelta`, the metrics service's alone).
///
/// ```swift
/// let reader = CEFHistogramReader(engine: services.cache.chromium)
/// await reader.reset()
/// // ... input to a Chromium page ...
/// let report = await reader.read()
/// ```
public actor CEFHistogramReader {
    /// One `Browser.getHistograms` call with `query` (a name substring): its result JSON.
    public typealias Fetch = @MainActor @Sendable (_ query: String) async -> Result<String, CEFHistogramReadError>

    /// The name substrings asked for: Chromium's per-event latency (cc/metrics/compositor_frame_reporter.cc),
    /// its scroll jank (cc/metrics/scroll_jank_dropped_frame_tracker.cc) and the browser's scroll update
    /// latency (ui/latency/latency_tracker.cc).
    nonisolated static let queries = ["EventLatency.", "Event.ScrollJank.", "Event.Latency.ScrollUpdate."]

    private let fetch: Fetch
    private var baseline: [String: CEFChromiumHistogram] = [:]

    /// - Parameter fetch: Runs one `Browser.getHistograms` call (``CEFEngine/histograms(query:)``; tests a fake).
    public init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    /// A reader over the App's engine slot. It builds no engine: before a Chromium need built one, every read
    /// says ``CEFHistogramReadError/noBrowser``.
    public init(engine slot: ChromiumEngineSlot) {
        self.init(fetch: { [weak slot] query in
            guard let engine = slot?.built else { return .failure(.noBrowser) }
            return await engine.histograms(query: query)
        })
    }

    /// Chromium's histograms now, less the baseline of the last ``reset()``.
    public func read() async -> ChromiumInputHistograms {
        switch await current() {
        case .success(let histograms):
            return ChromiumInputHistograms(folding: histograms.map { $0.subtracting(baseline[$0.name]) })
        case .failure(let error):
            return ChromiumInputHistograms(unavailable: error)
        }
    }

    /// Later reads count from now. A failed read keeps the old baseline.
    public func reset() async {
        guard case .success(let histograms) = await current() else { return }
        baseline = Dictionary(histograms.map { ($0.name, $0) }, uniquingKeysWith: { _, later in later })
    }

    /// Every histogram the queries name, by name.
    private func current() async -> Result<[CEFChromiumHistogram], CEFHistogramReadError> {
        var byName: [String: CEFChromiumHistogram] = [:]
        for query in Self.queries {
            let reply = await fetch(query).flatMap(CEFChromiumHistogram.decodeReply)
            switch reply {
            case .failure(let error): return .failure(error)
            case .success(let histograms): for histogram in histograms { byName[histogram.name] = histogram }
            }
        }
        return .success(byName.values.sorted { $0.name < $1.name })
    }
}

extension CEFEngine {
    /// One `Browser.getHistograms` call (`query`: a name substring, `delta` off) through the DevTools
    /// session of an open Chromium page: Chromium's histograms are per browser process, so any page
    /// answers for all. Starts nothing: with no page open the answer is ``CEFHistogramReadError/noBrowser``.
    public func histograms(query: String) async -> Result<String, CEFHistogramReadError> {
        let runtime = CEFRuntime.shared
        guard runtime.shim != nil,
              let browser = runtime.tabsByBrowser.filter({ !$0.value.isClosed }).keys.min() else { return .failure(.noBrowser) }
        do {
            return .success(try await runtime.devTools(browser, method: "Browser.getHistograms", params: ["query": query, "delta": false]))
        } catch let error as BrowserTabError {
            switch error {
            case .closed: return .failure(.noBrowser)
            case .timedOut: return .failure(.timedOut)
            case .javaScript(let json): return .failure(.protocolError(json))
            case .snapshotUnavailable, .unsupported: return .failure(.protocolError(String(describing: error)))
            }
        } catch {
            return .failure(.protocolError(String(describing: error)))
        }
    }
}
