/// A ``ChromiumHostSupervising`` that reports when its host ends (p08-startup-046). The runtime
/// follows it from its adopt (`CEFRuntime.adopt`): every page the host showed gets the crash
/// state of its end, the runtime attaches again at its next start, and cmux keeps running, as
/// Chrome keeps the browser up when a child process dies and shows each of its tabs a sad tab
/// (chrome/browser/ui/sad_tab_helper.cc).
///
/// `ChromiumHostSupervisor` conforms: task 080 of plans/cmux-next/chrome-parity/p01-process.md
/// (its change and acceptance name this contract) watches its host's exit off the main thread and
/// maps it with `ChromiumHostExit.pageExit`.
public protocol ChromiumHostExitReporting: ChromiumHostSupervising {
    /// Runs on the main thread each time a host that said hello ends while cmux is not quitting,
    /// with the crash state its pages show. A clean exit (status 0) reports nothing. It may run before
    /// or after the ``ChromiumHostSupervising/observeHostEnds(_:)`` observers of the same end: the
    /// runtime detaches the dead wire on whichever comes first (task 091).
    var onHostEnded: (@MainActor (BrowserProcessExit) -> Void)? { get set }
}
