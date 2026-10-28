import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextWakeups
import Foundation

/// `window.screenshot`, `pane.screenshot` and `tab.screenshot`: a PNG of one
/// of this app's windows, a pane, or a tab's content, for agents that cannot
/// see the screen (`cmux window screenshot [--target win_…] [--out PATH|-]`,
/// the same verbs over MCP, the palette and the Copy menus).
///
/// The image is the app's own window as on screen (``AppWindowImage``): no
/// Screen Recording grant, no focus or selection change, no activation, and
/// it works for a background or covered window. A pane or tab is cropped from
/// its window. A browser tab that no window shows (another workspace, a tab
/// behind the selected one) is rendered by its page engine in the background
/// instead. A capture that cannot give pixels fails with
/// `screenshot.unavailable` and the reason, never a blank image.
///
/// The run's `result` holds `path` (or `png_base64` for `out: "-"` when the
/// PNG fits one answer), `width` and `height` (pixels), `scale` (pixels per
/// point) and `method` (`window` or `page`). A person's run (palette, menu)
/// also copies the image.
///
/// An automation run (CLI, MCP, scripts) gets the same image with every web
/// page the app does not own painted black (``ScreenshotPrivacyMask``): the
/// app cannot mask the secrets a page shows the way the browser host does, so
/// a browser tab or a pane showing one is refused and points at the browser
/// REPL, whose capture masks them.
enum ScreenshotHandlers {
    /// The capture gave no image; the message says why.
    static let unavailableCode = "screenshot.unavailable"
    /// The PNG could not be written where `out` names.
    static let writeFailedCode = "screenshot.write_failed"
    /// A hibernated page was not woken for the capture: memory is low, so retry later. Its data's
    /// `deferral` is the ``WakeAdmission/Deferral``.
    static let deferredCode = "screenshot.deferred"

    /// Why an off-screen page did not wake for a capture: ``deferredCode`` with the deferral when the wake
    /// admission held it back, else ``unavailableCode``.
    static func wakeFailure(_ key: String, cache: TabContentCache) -> ActionWorkFailure {
        guard let deferral = cache.hibernation?.deferral(of: key) else {
            return ActionWorkFailure(code: unavailableCode, reason: BrowserPageStrings.wakeFailed)
        }
        return ActionWorkFailure(code: deferredCode, reason: BrowserPageStrings.wakeDeferred, details: ["deferral": deferral.rawValue])
    }

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("window.screenshot", run: { invocation in
            let output = try ScreenshotOutput(invocation)
            guard let window = try context.window(invocation).window else { throw ActionFailure(message: ScreenshotStrings.notOnScreen) }
            start(output: output, invocation: invocation, context: context) {
                try await shown(window, crop: nil, masked: ScreenshotPrivacyMask.applies(to: invocation), services: context.services)
            }
        })
        registry.bind("pane.screenshot", run: { invocation in
            let output = try ScreenshotOutput(invocation)
            // The scope refuses a target that names nothing or no window shows.
            guard let pane = context.scope(invocation).pane else {
                if invocation.target == nil { throw ActionFailure(message: MiscHandlerStrings.noPane) }
                return
            }
            // R-vis: the pane's node (an occluded window still captures; a hidden pane does not).
            guard let window = pane.view.window, pane.isVisible, pane.visibilityNode.effective != .hidden else {
                throw ActionFailure(message: ScreenshotStrings.paneNotShown)
            }
            let masked = ScreenshotPrivacyMask.applies(to: invocation)
            if masked, case .browser? = pane.currentContent { throw ActionFailure(message: ScreenshotStrings.browserNeedsREPL) }
            let view = pane.view
            start(output: output, invocation: invocation, context: context) {
                try await shown(window, crop: view, masked: masked, services: context.services)
            }
        })
        registry.bind("tab.screenshot", run: { invocation in
            let output = try ScreenshotOutput(invocation)
            let (tab, controller) = try resolveTab(invocation, services: context.services)
            let masked = ScreenshotPrivacyMask.applies(to: invocation)
            if masked, tab.kind == .browser { throw ActionFailure(message: ScreenshotStrings.browserNeedsREPL) }
            if let controller, let window = controller.view.window, controller.isVisible, controller.currentTabKey == tab.id,
               controller.visibilityNode.effective != .hidden {
                let view = controller.view.contentHost
                start(output: output, invocation: invocation, context: context) {
                    try await shown(window, crop: view, masked: masked, services: context.services)
                }
                return
            }
            // No window shows it: only a page engine renders off screen.
            guard tab.kind == .browser else {
                throw ActionFailure(message: tab.kind == .pty ? ScreenshotStrings.terminalNotShown : ScreenshotStrings.tabNotShown)
            }
            start(output: output, invocation: invocation, context: context) {
                try await offscreenPage(tab, services: context.services)
            }
        })
    }

    /// The tab the run names (target or `tab` argument, in any workspace),
    /// else the focused pane's selected tab, with the controller that shows
    /// its pane, if any.
    private static func resolveTab(_ invocation: ActionInvocation, services: AppServices) throws -> (TabModel, PaneController?) {
        if let target = invocation.target ?? invocation["tab"]?.targetValue, target.kind == .tab {
            guard let (tab, pane) = services.machines.tabIndex.locate(target.id) else {
                throw ActionFailure(message: RefusalStrings.noTab(target.id), isNotFound: true)
            }
            return (tab, services.paneController(for: pane))
        }
        guard let pane = services.windows.active?.focusedPane else { throw ActionFailure(message: MiscHandlerStrings.noPane) }
        guard let id = pane.stripModel.selectedID, let tab = pane.tab(id) else {
            throw ActionFailure(message: RefusalStrings.focusedPaneHasNoTab)
        }
        return (tab, pane)
    }

    /// One capture: the image, its scale (pixels per point) and how it was made.
    struct Capture {
        let image: CGImage
        let scale: Double
        let method: String
    }

    /// `window` as on screen, cropped to `crop`'s frame when given; `masked`
    /// for an automation run (``ScreenshotPrivacyMask``).
    private static func shown(_ window: NSWindow, crop view: NSView?, masked: Bool, services: AppServices) async throws -> Capture {
        let full = try await AppWindowImage(services: services).capture(window, masked: masked)
        let size = window.frame.size
        let scale = size.width > 0 ? Double(full.width) / size.width : Double(window.backingScaleFactor)
        guard let view else { return Capture(image: full, scale: scale, method: "window") }
        // The view may have left the window while the capture ran.
        guard view.window === window,
              let cropped = full.cropped(toWindowRect: view.convert(view.bounds, to: nil), windowSize: size) else {
            throw ActionWorkFailure(code: unavailableCode, reason: ScreenshotStrings.outsideWindow)
        }
        return Capture(image: cropped, scale: scale, method: "window")
    }

    /// A browser tab no window shows, rendered by its engine in the
    /// background: a hibernated page wakes and a Chromium page that never
    /// had a browser gets one, without focus or selection changes
    /// (`AppBrowserPage`).
    private static func offscreenPage(_ tab: TabModel, services: AppServices) async throws -> Capture {
        var made = (services.cache.existingBrowser(tab.id) ?? services.cache.browser(for: tab))?.tab
        if made == nil { made = await AppBrowserPage.awaitPage(tab.id, services: services, within: AppBrowserPage.actionWait) }
        guard let made else { throw ActionWorkFailure(code: unavailableCode, reason: ScreenshotStrings.pageFailed("no page")) }
        services.cache.hibernation?.noteAgentUse(tab.id)
        guard let page = await AppBrowserPage.awakePage(tab.id, page: made, cache: services.cache, within: AppBrowserPage.actionWait) else {
            throw wakeFailure(tab.id, cache: services.cache)
        }
        do {
            try await AppBrowserPage.ensureBrowser(page)
            let image = try await page.snapshot()
            let width = page.contentView.bounds.width
            return Capture(image: image, scale: width > 0 ? Double(image.width) / width : 1, method: "page")
        } catch {
            throw ActionWorkFailure(code: unavailableCode, reason: ScreenshotStrings.pageFailed(String(describing: error)))
        }
    }

    /// Starts the capture and reports it as the run's result
    /// (`ActionRegistry.track(result:)`). A person's run copies the image
    /// and shows a failure in the refusal toast.
    private static func start(output: ScreenshotOutput, invocation: ActionInvocation, context: AppActionContext,
                              capture: @escaping @MainActor () async throws -> Capture) {
        let services = context.services
        let byPerson = invocation.origin == .user
        // task-owner: the action run; a capturing caller awaits it through the registry.
        // main-hop-allow: the capture reads the window, its views and the page between its awaits (AppWindowImage and AppBrowserPage are main-actor async); the registry tracks this run as the action's result
        let task: ActionResultWork = Task { @MainActor in
            do {
                return .success(try await deliver(try await capture(), output: output, copies: byPerson, runner: services.work))
            } catch let failure as ActionWorkFailure {
                return .failure(failure)
            } catch let failure as WindowScreenshotFailure {
                return .failure(ActionWorkFailure(code: unavailableCode, reason: ScreenshotStrings.reason(failure)))
            } catch {
                return .failure(ActionWorkFailure(code: unavailableCode, reason: String(describing: error)))
            }
        }
        context.registry.track(result: task)
        guard byPerson else { return }
        let mainWork = services.mainWork
        // task-owner: shows a person's failed capture once; ends with the capture. R-hop: awaited off main; the
        // refusal shows in one userBlocking task (the rest of the person's action, Chrome kUserBlocking).
        services.work.task(.userBlocking) {
            guard case .failure(let failure) = await task.value else { return }
            mainWork.postFromAnyThread(.userBlocking, owner: "screenshot.refusal") {
                services.refusalHUD.show(failure.message, in: services.windows.active?.window)
            }
        }
    }

    /// Encodes and writes `capture` where `output` says.
    private static func deliver(_ capture: Capture, output: ScreenshotOutput, copies: Bool,
                                runner: any MayBlockRunner) async throws -> [String: ActionResultValue] {
        let image = capture.image
        let encoded = await encode(image)
        guard !encoded.blank else { throw ActionWorkFailure(code: unavailableCode, reason: ScreenshotStrings.blank) }
        guard let png = encoded.png else { throw ActionWorkFailure(code: unavailableCode, reason: BrowserPageStrings.encodeFailed) }
        var result: [String: ActionResultValue] = [
            "width": .int(image.width), "height": .int(image.height), "scale": .double(capture.scale), "method": .string(capture.method),
        ]
        do {
            switch output {
            case .inline where png.count <= AppBrowserPage.inlinePNGLimit:
                // Up to 4 MiB of PNG grows to 5.3 MiB of text: off the main actor.
                result["png_base64"] = .string(await AppBrowserPage.base64(png))
            case .inline, .temporary:
                result["path"] = .string(try await saveTemporary(png, on: runner))
            case .file(let url):
                try await write(png, to: url, on: runner)
                result["path"] = .string(url.path)
            }
        } catch {
            throw ActionWorkFailure(code: writeFailedCode, reason: BrowserPageStrings.saveFailed(error.localizedDescription))
        }
        if copies {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: .zero)])
        }
        return result
    }

    /// The blank check (a 64 x 64 redraw) and the PNG encoding, off the main actor: a Retina
    /// window is several megapixels. `png` is nil for a blank image or a failed encoding.
    @concurrent
    nonisolated private static func encode(_ image: CGImage) async -> (blank: Bool, png: Data?) {
        if image.isFullyTransparent { return (true, nil) }
        return (false, image.pngData())
    }

    /// The caller waits for the file: the files lane at userBlocking.
    private static func write(_ png: Data, to url: URL, on runner: any MayBlockRunner) async throws {
        try await runner.runFiles(.userBlocking) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
        }
    }

    /// Writes to `$TMPDIR/cmux-screenshots/`, pruned as browser screenshots are.
    private static func saveTemporary(_ png: Data, on runner: any MayBlockRunner) async throws -> String {
        try await runner.runFiles(.userBlocking) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-screenshots", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // wall-clock: a file name stamp; pruning reads the files' dates.
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            let file = directory.appendingPathComponent("screenshot-\(stamp)-\(UUID().uuidString.prefix(8)).png")
            try png.write(to: file, options: .atomic)
            AppBrowserPage.prune(directory, keeping: AppBrowserPage.keptScreenshots,
                                 newerThan: Date().addingTimeInterval(-AppBrowserPage.screenshotLifetime))
            return file.path
        }
    }
}
