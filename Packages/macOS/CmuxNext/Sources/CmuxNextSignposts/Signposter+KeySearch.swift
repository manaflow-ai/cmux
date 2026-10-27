import CmuxNextTrace
import class CmuxSafeConcurrency.Invariant
import os

// The `key.omnibar_suggest` and `key.palette_search` slices (p09-observability task 040, perf-hot `omnibar-key` and
// `palette-key`; owners PL-typing and the Performance Lead). Each is one thread slice (B/E) per synchronous pass of a
// search that a typed key drives: the pass that takes the new query and the pass that takes its rows when they land,
// as Chrome traces `AutocompleteController::Start` and `AutocompleteController::UpdateResult` as separate slices
// (components/omnibox/browser/autocomplete_controller.cc). The pass is in the begin record's `arg0` and the rows the
// list holds when the pass ends in the end record's `arg0`. Keystroke timing: nothing is recorded, in the log or the
// ring, while the keystroke-timing gate is closed (``TraceRuntime/isKeyTimingSuppressed``, task 128), because
// ``isEnabled`` is false then. Not mirrored to MetricKit (a per-key name). The fields are formatted by the log system
// only when something reads it, so no pass builds a `String`.
nonisolated extension Signposter {
    /// Which pass of a typed key's search a ``SignpostName/keyOmnibarSuggest`` or ``SignpostName/keyPaletteSearch``
    /// slice times: its code in the begin record's `arg0`. Fixed and nonzero, so rings written by an older build
    /// decode with the same numbers.
    public nonisolated enum KeySearchPass: UInt64, Sendable {
        /// The query changed (a typed key, an edit, a source that changed the rows to search): the pass that
        /// starts the search and shows what it can at once.
        case query = 1
        /// The search's rows landed and the pass reduced them into the list.
        case results = 2
        /// More rows of the same query landed (the omnibar's slower providers) and the pass merged them in.
        case moreResults = 3
    }

    /// Begins a ``SignpostName/keyOmnibarSuggest`` or ``SignpostName/keyPaletteSearch`` slice (`pass=<code>`), or
    /// returns nil while nothing takes the key category (``isEnabled``, false while the keystroke-timing gate is
    /// closed). End it on this thread, in the same call, with ``end(_:_:results:)``.
    ///
    /// - Parameters:
    ///   - name: ``SignpostName/keyOmnibarSuggest`` or ``SignpostName/keyPaletteSearch``.
    ///   - searchPass: Which pass the slice times.
    /// - Returns: The state to pass to ``end(_:_:results:)``.
    public func begin(_ name: SignpostName, searchPass: KeySearchPass) -> SignpostInterval? {
        Invariant.debugCheck(name == .keyOmnibarSuggest || name == .keyPaletteSearch, "key-search-slice",
                             "\(name) is not a key search slice")
        guard isEnabled else { return nil }
        let code = searchPass.rawValue
        return openInterval(name, arg0: code) {
            signposter.beginInterval(name.staticName, id: $0, "pass=\(code, privacy: .public)")
        }
    }

    /// Ends a slice begun with ``begin(_:searchPass:)``: the log system's end carries `results=<count>` and the
    /// ring's E holds the count in `arg0`. `results` is read only when the begin recorded the slice.
    ///
    /// - Parameters:
    ///   - name: The name the slice began with.
    ///   - interval: What ``begin(_:searchPass:)`` returned (nil: nothing to end).
    ///   - results: The rows the list holds when the pass ends.
    public func end(_ name: SignpostName, _ interval: SignpostInterval?, results: @autoclosure () -> Int) {
        guard let interval else { return }
        let count = UInt64(max(results(), 0))
        signposter.endInterval(name.staticName, interval.state, "results=\(count, privacy: .public)")
        if let id = interval.metricKitID { mirror.end(name, id: id) }
        closeInterval(name, interval, arg0: count)
    }
}
