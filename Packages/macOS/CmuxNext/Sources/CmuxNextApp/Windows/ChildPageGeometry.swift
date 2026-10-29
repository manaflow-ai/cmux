import AppKit
import CmuxNextBrowser
#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextInputModel
import CmuxNextInvariants
#endif

/// Invariant: every visible Chromium page window covers its pane's page
/// area exactly, in screen coordinates, whatever moved or resized the
/// window (drag, an Accessibility client such as Rectangle, a display,
/// Space or fullscreen change). In process pages are child windows; the fork
/// places them from the host view's rect. In host mode a page is a view in its
/// pane (`ChromiumHostPageView`) that layout places like any other, so there is
/// no page window to check and ``sample(_:)`` reads nothing (task 028 of
/// plans/cmux-next/chrome-parity/p01-process.md).
enum ChildPageGeometry {
    /// Whether Chromium's pages are child windows of the cmux window under `backend`.
    static func hasPageWindows(_ backend: BrowserBackend) -> Bool { backend == .inProcess }

    /// One pane showing a Chromium page, and where its page must be.
    nonisolated struct Host: Equatable, Encodable, Sendable {
        var pane: String
        var screenRect: CGRect
    }

    /// What G1 reads of one window: its Chromium hosts and its page windows.
    nonisolated struct WindowSample: Equatable, Encodable, Sendable {
        var window: String
        var hosts: [Host]
        var pages: [CGRect]
    }

    /// Pixel rounding: the fork places windows on whole points.
    static let tolerance: CGFloat = 1

    static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.width - b.width), abs(a.height - b.height))
    }

    /// Violations: a host with no page window at its rect, or a visible page
    /// window at no host's rect.
    static func mismatches(hosts: [Host], pages: [CGRect]) -> [String] {
        var problems: [String] = []
        for host in hosts where !pages.contains(where: { distance($0, host.screenRect) <= tolerance }) {
            let nearest = pages.min { distance($0, host.screenRect) < distance($1, host.screenRect) }
            problems.append("pane \(host.pane): page \(nearest.map { "\($0)" } ?? "missing") != host \(host.screenRect)")
        }
        for page in pages where !hosts.contains(where: { distance(page, $0.screenRect) <= tolerance }) {
            problems.append("page window \(page) covers no pane")
        }
        return problems
    }

    /// Where the Chromium windows of one pane must be: the tab content, or,
    /// with DevTools docked, the page area and the DevTools area of the
    /// dock layout (each is its own child window). An undocked DevTools
    /// window is top-level, not a child of the cmux window, so it is not
    /// checked here.
    static func expectedHosts(pane: String, contentRect: CGRect, devTools: (page: CGRect, devTools: CGRect?)?) -> [Host] {
        guard let devTools, let docked = devTools.devTools else { return [Host(pane: pane, screenRect: contentRect)] }
        return [Host(pane: pane, screenRect: devTools.page), Host(pane: "\(pane) devtools", screenRect: docked)]
    }

    /// The window's Chromium hosts (visible, in this window) and page windows now; none in host mode.
    static func sample(_ controller: WindowController) -> (hosts: [Host], pages: [CGRect]) {
        guard hasPageWindows(controller.services.chromiumRuntime.backend), let window = controller.window else { return ([], []) }
        var hosts: [Host] = []
        for pane in controller.content?.panes.values.map({ $0 }) ?? [] {
            guard case .browser(let entry)? = pane.currentContent, entry.tab.presentation == .childWindow else { continue }
            let content = entry.tab.contentView
            // visibility-walk-allow: the check compares AppKit's own view state with the page windows the fork placed; a node would hide the mismatch it looks for
            guard content.window === window, !content.isHiddenOrHasHiddenAncestor, !content.bounds.isEmpty else { continue }
            let contentRect = window.convertToScreen(content.convert(content.bounds, to: nil))
            let devTools = (entry.tab as? CEFTab)?.devToolsDiagnosticFrames
            hosts += expectedHosts(pane: pane.paneKey, contentRect: contentRect, devTools: devTools)
        }
        let pages = window.isVisible ? WindowOverlayLayer.contentChildWindows(of: window).map(\.frame) : []
        return (hosts, pages)
    }

    /// Violations across every cmux window (for `debug.layers` and the input
    /// invariant monitor).
    static func check(_ services: AppServices) -> [String] {
        services.windows.controllers.flatMap { controller -> [String] in
            let (hosts, pages) = sample(controller)
            return mismatches(hosts: hosts, pages: pages).map { "window \(controller.state.id): \($0)" }
        }
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
extension ChildPageGeometry {
    /// Declares G1 (input-spec.md 2.6) in `registry`: every Chromium page window covers its pane in screen
    /// coordinates. The fork places page windows after a reply, and no in-flight ledger names that wait yet, so G1 is
    /// a harness rule for now (`interim`): `debug.invariants {check: true}` runs it after each journey step, once the
    /// step waited for its condition, never inside a turn. A window in a live resize is not checked (the fork follows
    /// each step): its signature stays as it was until a check sees the window at rest. A window with no Chromium
    /// host and no page window is checked and clean, so a G1 from before its pages closed clears.
    static func declareInvariants(in registry: InvariantRegistry, services: AppServices) {
        registry.declare(InvariantRule(
            id: "G1", row: "p11-11", statement: InputInvariant.chromiumGeometry.summary, owner: "Windows",
            reads: [.paneFrame, .presentation], points: .harness, cost: .walk, parity: false,
            interim: "harness only (after each journey step) until the Chromium geometry in-flight ledger exists",
            read: { [weak services] (pass: InvariantPass) -> [WindowSample]? in
                guard let services else { return nil }
                return services.windows.controllers.compactMap { controller -> WindowSample? in
                    guard controller.window?.inLiveResize != true else {
                        pass.skip(.window(controller.state.id))
                        return nil
                    }
                    let (hosts, pages) = sample(controller)
                    return WindowSample(window: controller.state.id, hosts: hosts, pages: pages)
                }
            },
            check: { samples in
                samples.flatMap { window in
                    mismatches(hosts: window.hosts, pages: window.pages).map { InvariantFinding(subject: .window(window.window), detail: $0) }
                }
            }))
    }
}
#endif
