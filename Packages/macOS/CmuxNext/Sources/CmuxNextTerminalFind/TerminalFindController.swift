public import Observation

/// One terminal's find bar: what it shows and how it drives the search.
///
/// Placeholder API for the failing tests; the behavior lands with the
/// inline find bar.
@MainActor
@Observable
public final class TerminalFindController {
    public private(set) var isPresented = false
    public private(set) var query = ""
    public private(set) var total: Int?
    public private(set) var selected: Int?
    public private(set) var focusRequest = 0

    public var count: TerminalFindCount {
        TerminalFindCount(query: query, total: total, selected: selected)
    }

    @ObservationIgnored public weak var target: (any TerminalFindTarget)?

    public init(target: (any TerminalFindTarget)? = nil) {
        self.target = target
    }

    public func open(seed: String? = nil) {}
    public func updateQuery(_ text: String) {}
    @discardableResult
    public func navigate(_ direction: TerminalFindDirection) -> Bool { false }
    public func close() {}
    public func searchStarted(needle: String) {}
    public func searchEnded() {}
    public func receiveTotal(_ total: Int?) {}
    public func receiveSelected(_ selected: Int?) {}
}
