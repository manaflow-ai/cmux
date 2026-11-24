import AppKit
import CmuxNextBrowser
import CmuxNextControl
import CmuxNextDesign
import CmuxNextPages
import CmuxNextScreenshots
import CmuxNextSettings
import WebKit

/// `debug.window_snapshot`: one of this app's own windows as the window
/// server composited it (vibrancy, glass and Metal as on screen; an app may
/// read its own windows without Screen Recording permission), else drawn
/// by AppKit (`NSWindow.renderSnapshot`, where Metal content and blur
/// differ from the screen). `method` says which (plans/cmux-next/windows.md).
///
/// Params: `window` (a main window id, or any window's number from
/// `debug.window_list`: popovers, panels and sheets too), or `kind`
/// (a `WindowKind` raw value: `main`, `settings`, `debugSettings`,
/// `appStore`, `onboarding`, ...);
/// default the key window, else the active main window. `path` is the PNG
/// to write (default a file in the temporary directory). Returns `path`,
/// `width`, `height` (pixels), `kind`, `window_number`, `method`
/// (`composited` or `appkit`), `child_windows` (how many of the window's
/// visible child windows the image includes) and `child_windows_failed`
/// (how many it leaves out because the window server gave no image of
/// them; AppKit drawing never includes a child window). Child windows are
/// composited by the window server with the window: a Chromium page draws
/// into its own child window, and overlay panels and popovers sit above content.
/// `floating_windows` counts the app's other windows the window server shows
/// above the window and over it, cut to its frame: an open
/// context menu (not in AppKit's window list), a hover card or popover that is
/// not its child; another of the app's titled windows in front at the same
/// level, with its own child windows and sheets, is left out. The window, its
/// child windows and those windows are one window server composite
/// (``NSWindow/compositedImageWithOverlays(cuttingOverlays:capture:)``), so a glass popover or menu
/// blurs the window under it, as on screen (composited apart, it came out grey). The
/// async verb also paints each engine's own image of every shown page
/// (`webviews`, `chromium_pages`, with `_composited` and `_failed` counts; a failed
/// Chromium page, as one waiting in a dialog, shows striped),
/// and of their docked DevTools (`devtools_not_captured`: striped, Chromium gave no image),
/// since the window server
/// leaves out page content other processes draw unless the app has the
/// Screen Recording grant. `webviews: false` skips the page images (the
/// window server's image alone).
///
/// A refusal (`RefusalHUD`) shows as a toast that fades in and ends after 4 s (later while the
/// pointer is on it), so its pixels are not a reliable assertion: a capture may land before the
/// fade or after it ends. Every reply therefore carries `refusal_hud`: the message the refusal
/// toast shows now (null when none) and `refusal_hud_count`, the messages shown so far. Check
/// those (or `debug.toast`) instead of looking for the toast in the PNG.
enum DebugWindowSnapshot {
    /// How long `debug.window_snapshot` may take, instead of the 2 s control-plane deadline. The
    /// capture runs on the main actor and takes about 50 ms once it runs, but on a capture mini
    /// that also runs builds and tests, or while the app is still launching, the wait for the
    /// main actor alone passed 2 s: the snapshot timed out and the capture had no still. Its
    /// callers wait 10 to 90 s (pr-capture's driver 30 s).
    static let deadline: Duration = .seconds(30)

    /// The control route, `debug.window_snapshot`, with its own ``deadline``.
    static func controlMethod(services: AppServices) -> ControlMethod {
        .async("debug.window_snapshot") { [weak services] call in
            guard let services = await MainActor.run(body: { services }) else { return .null }
            return await captureAsync(call.params, services: services)
        }.withDeadline(.fixed(deadline))
    }

    /// The app selects the window and supplies Chromium’s page layers. The renderer owns the PNG and its report.
    @MainActor
    static func captureAsync(_ params: [String: JSONValue], services: AppServices) async -> JSONValue {
        guard let window = window(params, services: services) else { return .object(["error": .string("no such window")]) }
        let kind = kind(of: window, services: services)
        let path = params["path"]?.stringValue.map { ($0 as NSString).expandingTildeInPath }
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("cmux-window-\(kind)-\(window.windowNumber).png")
        let result: JSONValue
        if params["webviews"]?.boolValue == false {
            result = await WindowSnapshotRenderer.captureNative(window: window, kind: kind, path: path)
        } else {
#if DEBUG || CMUX_BENCH_HOOKS
            // An inactive floating palette can have a blank standalone window-server image.
            if services.palette.owns(window) { return DebugPaletteCapture.capture(params.merging(["path": .string(path)]) { $1 }, services: services) }
#endif
            result = await WindowSnapshotRenderer.capturePages(window: window, kind: kind, path: path,
                                                               includeChromiumPages: params["chromium_pages"]?.boolValue != false,
                                                               isSuspended: { $0.cmuxIsSuspended }) { skip in
                await AppWindowImage.pageLayers(in: window, services: services, skip: skip)
            }
        }
        guard case .object(var report) = result, report["error"] == nil else { return result }
        report["refusal_hud"] = services.refusalHUD.message.map(JSONValue.string) ?? .null
        report["refusal_hud_count"] = JSONValue(services.refusalHUD.shownCount)
        return .object(report)
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// `debug.capture_backdrop` (DEBUG builds): shows `pattern` (`checker`, `stripes`,
    /// `image:/absolute/path`; `none` removes it) just behind the window `window` or `kind` names,
    /// as for a snapshot, so a snapshot of that window composites it behind the window and its
    /// translucency and glass show (``CaptureBackdropPanel``). Returns `pattern`, `window_number`
    /// and `backdrop_number` (null after `none`).
    @MainActor
    static func captureBackdrop(_ params: [String: JSONValue], pattern: CaptureBackdropPattern?, image: Data?,
                                services: AppServices) -> JSONValue {
        let name = params["pattern"]?.stringValue ?? ""
        guard name == "none" || pattern != nil else {
            return .object(["error": .string("pattern must be checker, stripes, image:/absolute/path or none")])
        }
        guard let window = window(params, services: services) else { return .object(["error": .string("no such window")]) }
        var picture: NSImage?
        if case .image(let url) = pattern {
            guard let image, let decoded = NSImage(data: image) else { return .object(["error": .string("no image at \(url.path)")]) }
            picture = decoded
        }
        let backdrop = window.setCaptureBackdrop(pattern, image: picture)
        return .object(["pattern": .string(name), "window_number": JSONValue(window.windowNumber),
                        "backdrop_number": backdrop.map { JSONValue($0.windowNumber) } ?? .null])
    }
    #endif

    /// The Chromium pages shown in `window`'s panes, with the page area in
    /// window coordinates (beside a docked DevTools, which has its own layer).
    @MainActor
    static func chromiumPages(in window: NSWindow, services: AppServices) -> [(CEFTab, NSRect)] {
        guard let controller = services.windows.controllers.first(where: { $0.window === window }) else { return [] }
        var result: [(CEFTab, NSRect)] = []
        for pane in controller.content?.panes.values.map({ $0 }) ?? [] {
            guard case .browser(let entry)? = pane.currentContent, let page = entry.tab as? CEFTab,
                  page.contentView.window === window, !page.contentView.isHiddenOrHasHiddenAncestor else { continue }
            let rect = page.devToolsDiagnosticFrames.map { window.convertFromScreen($0.page) }
                ?? page.contentView.convert(page.contentView.bounds, to: nil)
            guard rect.width > 0, rect.height > 0 else { continue }
            result.append((page, rect))
        }
        return result
    }

    /// The window `params` names.
    static func window(_ params: [String: JSONValue], services: AppServices) -> NSWindow? {
        let windows = NSApp.windows
        if let id = params["window"]?.stringValue ?? params["window"]?.intValue.map(String.init) {
            if let main = services.windows.controller(for: id)?.window { return main }
            return windows.first { String($0.windowNumber) == id }
        }
        if let kind = params["kind"]?.stringValue {
            if kind == "main" { return services.windows.active?.window }
            return windows.first { $0.isVisible && Self.kind(of: $0, services: services) == kind }
        }
        return NSApp.keyWindow ?? services.windows.active?.window
    }

    /// The window's kind as `debug.window_list` names it.
    static func kind(of window: NSWindow, services: AppServices) -> String {
        DebugWindowList.kind(of: window, services: services)
    }
}
