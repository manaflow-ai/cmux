#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextDesign
import CmuxNextSettings

/// `debug.open_panel_bench` (DEBUG builds): one file-picker open as a click runs it (Home's "+", an agent
/// composer's Attach), timed to the display frame that shows the sheet, then cancelled.
///
/// Params: `mode` — `made` (default: the panel made ahead, ``MadeAheadOpenPanel``, warmed first, as Home's
/// "+" takes it), `fresh` (a new `NSOpenPanel()` per open: the on-demand path when none was made ahead) or
/// `window` (`begin(completionHandler:)`, a separate panel window instead of a sheet); `window` (default: the
/// first window).
///
/// Reports, in ms from the click: `init_ms` (getting the panel: `NSOpenPanel()` or the reuse),
/// `begin_ms` (the `beginSheetModal` / `begin` call), `sync_ms` (both: the click's main-thread time),
/// `visible_ms` (the first display frame with the panel on screen), `frames` (the display-link intervals
/// from 120 ms before the click until 300 ms after it showed: `max_ms` is the longest the main thread held a frame;
/// a call that runs a nested run loop, as `beginSheetModal` does while the sheet animates, keeps it near one frame).
@MainActor
enum DebugOpenPanelBench {
    private static let frames = BenchFrames()

    // Diagnostic modes (side branch pl-openpanel-probe, not for landing): which sheets stall main, and whether a sheet
    // with no open animation (`animationResizeTime` 0 on the sheet, on the parent, or NSWindowResizeTime) still does.
    //   made_noanim   a made-ahead NoAnimOpenPanel (NSOpenPanel subclass, animationResizeTime 0) as a sheet
    //   save          a made-ahead NSSavePanel as a sheet
    //   alert         an NSAlert as a sheet (Files, Screenshots)
    //   plain         a plain NSWindow as a sheet (Home group info, Home sheet, update sheet, SwiftUI .sheet)
    //   plain_noanim  a NoAnimWindow (animationResizeTime 0) as a sheet
    //   plain_parent  a plain sheet on a probe parent window whose animationResizeTime is 0 (which window AppKit asks)
    //   plain_animnone / made_animnone  the sheet's animationBehavior is .none
    //   plain_child / made_child  no sheet: the window shows as a child window at the sheet's place (made: `begin`)
    //   made_default  the made-ahead panel while NSWindowResizeTime is registered as 0.001 (removed after the open)
    //   overlay       a CmuxDialog in the window scope (the in-window overlay layer), the path an NSAlert or a plain
    //                 sheet window could take instead of an AppKit sheet
    static func run(_ params: [String: JSONValue], _ services: AppServices?) async -> JSONValue {
        guard let services else { return .null }
        let mode = params["mode"]?.stringValue ?? "made"
        if mode == "overlay" { return await overlay(services) }
        guard let personWindow = services.windows.controllers.first?.window else { return .object(["error": .string("no window")]) }
        guard personWindow.attachedSheet == nil else { return .object(["error": .string("the window already shows a sheet")]) }
        let shared = services.openPanel
        if mode == "made" || mode == "made_default", !shared.isMade {
            shared.warmWhenIdle()
            frames.start()
            _ = await frames.settled(until: { shared.isMade || !shared.isWarming }, start: .now, window: 0, deadline: 8_000)
            _ = frames.stop()
        }
        if mode == "made_default" { UserDefaults.standard.register(defaults: ["NSWindowResizeTime": 0.001]) }
        // Made outside the timed span, as a made-ahead panel is.
        let noAnimPanel = mode == "made_noanim" ? NoAnimOpenPanel() : nil
        let savePanel = mode == "save" ? NSSavePanel() : nil
        var window = personWindow
        var probeParent: NoAnimWindow?
        if mode == "plain_parent" {
            let parent = NoAnimWindow(contentRect: personWindow.frame, styleMask: personWindow.styleMask, backing: .buffered, defer: false)
            parent.isReleasedWhenClosed = false
            parent.setFrame(personWindow.frame, display: true)
            parent.orderFront(nil)
            probeParent = parent
            window = parent
        }
        let madeBefore = shared.isMade
        // Quiet frames first, so the click starts from an idle main thread, and the display link keeps ticking into
        // the click: a stall of the click's own main-thread work then shows as one long frame interval (frames.max_ms),
        // while a nested run loop (a sheet animating inside the call) keeps the frames coming.
        frames.start()
        _ = await frames.settled(until: { true }, start: .now, window: 120, deadline: 1_000)
        let start = ContinuousClock.now
        let sheet: NSWindow
        var alert: NSAlert?
        switch mode {
        case "fresh", "window": sheet = NSOpenPanel()
        case "made_noanim": sheet = noAnimPanel ?? NoAnimOpenPanel()
        case "save": sheet = savePanel ?? NSSavePanel()
        case "alert":
            // dialog-keys-exempt: a probe of the system alert sheet's cost (side branch, never shown to a person)
            let a = NSAlert()
            a.messageText = "Probe"
            a.informativeText = "A sheet the open-panel probe shows and cancels."
            alert = a
            sheet = a.window
        case "plain", "plain_parent", "plain_animnone", "plain_child": sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        case "plain_noanim": sheet = NoAnimWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        default:
            guard let panel = shared.panel() else {
                _ = frames.stop()
                return .object(["mode": .string(mode), "error": .string("the panel came back dead (no prompt)")])
            }
            sheet = panel
        }
        let behavior = sheet.animationBehavior
        if mode.hasSuffix("_animnone") { sheet.animationBehavior = .none }
        let child = mode.hasSuffix("_child")
        let made = ContinuousClock.now
        if mode == "window" || mode == "made_child", let panel = sheet as? NSOpenPanel {
            panel.begin { _ in }
        } else if child {
            sheet.orderFront(nil)
        }
        if child {
            let content = window.contentLayoutRect
            let top = window.convertPoint(toScreen: NSPoint(x: content.midX - sheet.frame.width / 2, y: content.maxY))
            sheet.setFrameTopLeftPoint(top)
            window.addChildWindow(sheet, ordered: .above)
        } else if mode == "window" {
            // shown by `begin` above
        } else if let alert {
            alert.beginSheetModal(for: window) { _ in }
        } else if let panel = sheet as? NSSavePanel {
            panel.beginSheetModal(for: window) { _ in }
        } else {
            window.beginSheet(sheet) { _ in }
        }
        let begun = ContinuousClock.now
        let visible = await frames.settled(until: {
            sheet.isVisible && sheet.occlusionState.contains(.visible) && (mode == "window" || child || window.attachedSheet === sheet)
        }, start: start, window: 300, deadline: 10_000)
        let stats = frames.stop()
        let calls: JSONValue = .object([
            "sheet": .number(Double((sheet as? NoAnimOpenPanel)?.resizeTimeCalls ?? (sheet as? NoAnimWindow)?.resizeTimeCalls ?? -1)),
            "parent": .number(Double(probeParent?.resizeTimeCalls ?? -1)),
        ])
        if child { window.removeChildWindow(sheet) }
        if mode == "window" || mode == "made_child", let panel = sheet as? NSOpenPanel {
            panel.cancel(nil)
        } else if child {
            sheet.orderOut(nil)
        } else {
            window.endSheet(sheet, returnCode: .cancel)
        }
        frames.start()
        _ = await frames.settled(until: { !sheet.isVisible && window.attachedSheet == nil }, start: .now, window: 0, deadline: 3_000)
        _ = frames.stop()
        sheet.animationBehavior = behavior
        probeParent?.close()
        if mode == "made_default" {
            var registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
            registered.removeValue(forKey: "NSWindowResizeTime")
            UserDefaults.standard.setVolatileDomain(registered, forName: UserDefaults.registrationDomain)
        }
        return .object([
            "mode": .string(mode),
            "sheet_class": .string(String(describing: type(of: sheet))),
            "made_ahead_before": .bool(madeBefore),
            "prompt_nil": .bool((sheet as? NSSavePanel)?.prompt == nil),
            "init_ms": .number(BenchSpans.ms(made - start)),
            "begin_ms": .number(BenchSpans.ms(begun - made)),
            "sync_ms": .number(BenchSpans.ms(begun - start)),
            "visible_ms": visible.map { .number($0) } ?? .null,
            "frames": stats,
            "resize_time_calls": calls,
            "behavior": .number(Double(behavior.rawValue)),
        ])
    }
}

extension DebugOpenPanelBench {
    /// A CmuxDialog confirm in the first window's scope, timed as a sheet is: the present call, the first frame with
    /// its view on screen in the window, the longest frame; then dismissed.
    private static func overlay(_ services: AppServices) async -> JSONValue {
        guard let window = services.windows.controllers.first?.window else { return .object(["error": .string("no window")]) }
        let center = CmuxDialogCenter.shared
        let spec = CmuxDialogSpec(title: "Close Workspace “api”?", lines: ["vim and npm are still running."],
                                  buttons: [.cancel(), CmuxDialogButton(id: "close", title: "Close", role: .destructive)],
                                  identifier: "cmux.dialog.fixture.openpanel-probe")
        frames.start()
        _ = await frames.settled(until: { true }, start: .now, window: 120, deadline: 1_000)
        let start = ContinuousClock.now
        let id = center.present(spec, in: .window(window)) { _ in }
        let begun = ContinuousClock.now
        let visible = await frames.settled(until: {
            guard let view = center.view(id), view.window === window, !view.isHiddenOrHasHiddenAncestor else { return false }
            return view.visibleRect.width > 0
        }, start: start, window: 300, deadline: 10_000)
        let stats = frames.stop()
        center.dismiss(id)
        frames.start()
        _ = await frames.settled(until: { center.record(id) == nil }, start: .now, window: 0, deadline: 3_000)
        _ = frames.stop()
        return .object([
            "mode": .string("overlay"), "sheet_class": .string("CmuxDialog"),
            "init_ms": .number(0), "begin_ms": .number(BenchSpans.ms(begun - start)), "sync_ms": .number(BenchSpans.ms(begun - start)),
            "visible_ms": visible.map { .number($0) } ?? .null, "frames": stats,
        ])
    }
}

/// An open panel whose sheet asks for no open animation.
private final class NoAnimOpenPanel: NSOpenPanel {
    var resizeTimeCalls = 0
    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval {
        resizeTimeCalls += 1
        return 0
    }
}

/// A window that asks for no resize or sheet animation.
private final class NoAnimWindow: NSWindow {
    var resizeTimeCalls = 0
    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval {
        resizeTimeCalls += 1
        return 0
    }
}

#endif
