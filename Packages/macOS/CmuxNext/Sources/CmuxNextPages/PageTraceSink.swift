import CmuxNextSignposts
import CmuxNextTrace

/// Where the page host writes its `webui.*` trace points: the process's ``TraceRuntime`` in the app, a
/// recorder in tests (``PageWebView`` and ``PageSchemeHandler`` take it as an injected seam).
/// A begin returns whether it was written (its category was on), as ``TraceRuntime``'s typed points do.
protocol PageTraceSink: AnyObject {
    @discardableResult
    func begin(_ name: SignpostName, arg0: UInt64, arg1: UInt64) -> Bool
    func end(_ name: SignpostName, arg0: UInt64, arg1: UInt64)
    @discardableResult
    func asyncBegin(_ name: SignpostName, id: UInt64, arg0: UInt64) -> Bool
    func asyncEnd(_ name: SignpostName, id: UInt64, arg0: UInt64)
}

extension TraceRuntime: PageTraceSink {}

/// How a ``SignpostName/webuiOpen`` slice started: bits 0-7 of its begin `arg0`.
nonisolated enum PageOpenKind: UInt64 {
    /// A new view's own first load.
    case newView = 0
    /// A pooled spare's first document (``PageWebView/startLoading()``).
    case spare = 1
    /// A pooled host claimed for its own page: its parked document, or that document reloaded.
    case claim = 2
    /// Another document: a pooled host retargeted to another page, or a route loaded before the first load.
    case load = 3
    /// A reload: the host's, a crash reload, or the reopen in WebKit after Chromium ended.
    case reload = 4
    /// A document the page or another module navigated to; its slice starts at the commit.
    case navigated = 5
}

/// How a ``SignpostName/webuiOpen`` slice ended: its end `arg0`.
nonisolated enum PageOpenOutcome: UInt64 {
    case paintedInWebKit = 0
    case paintedInChromium = 1
    case closedBeforePaint = 2
    /// A newer open of the same view (a claim, a retarget) began before this one painted.
    case replaced = 3
}
