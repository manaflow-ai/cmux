public import Foundation

/// A ``ChromiumHostSupervising`` that reports when its host ends. The runtime
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
    /// Whether the pages of the last host that ended come back on a new host at once (task 083 of
    /// plans/cmux-next/chrome-parity/p01-process.md): its restart budget, Chrome's GPU crash budget
    /// (`GpuProcessHost::RecordProcessCrash`, content/browser/gpu/gpu_process_host.cc), had room for that
    /// end. Set before ``onHostEnded`` runs; false leaves each page's crash page until the person reloads it.
    var lastEndRestoresPages: Bool { get }
    /// Reads a tab's saved navigation for its page on the next host; nil brings each page back at its address.
    var savedNavigation: ChromiumHostSavedNavigation? { get }

    /// The host whose wire ``ChromiumHostSupervising/attachment()`` handed out said hello (`CEFHostStart`, on the main
    /// thread): from now on its end reaches ``onHostEnded``. A host that ends before this never does: it did not
    /// start, and no host starts again (the restart policy's cannot-start, task 081).
    func hostSaidHello()

    /// The host that said hello runs this Chromium fork API (its remote shim's mirror, read by `CEFHostStart` on the
    /// main thread): its crash record names it (task 085 of plans/cmux-next/chrome-parity/p01-process.md).
    func hostRuns(forkAPI: Int32)
}

extension ChromiumHostExitReporting {
    /// A supervisor with no restart budget restores no page: each one waits for the person's Reload.
    public var lastEndRestoresPages: Bool { false }
    /// No saved navigation: a restored page loads its address.
    public var savedNavigation: ChromiumHostSavedNavigation? { nil }
}

/// Reads tab `tab`'s saved Chromium navigation (the fork's `cmux_tab_navigation_state`, its back/forward list) from
/// its daemon history record (`frontend-browser-history-v1`), when that record was saved at `url` and may be
/// restored (no form submission in it, no file outside the shown page's folder); nil otherwise. The App reads the
/// record (`BrowserTabService.savedChromiumNavigation`): it outlives the host, as Chrome's session service keeps
/// each tab's `SerializedNavigationEntry` list outside the renderer (components/sessions/core/session_service_commands.cc).
public typealias ChromiumHostSavedNavigation = @MainActor @Sendable (_ tab: BrowserTabID, _ url: URL) async -> BrowserRestoreState?
