import AppKit
import CmuxNextBrowser
import CmuxNextCompat
import WebKit
import CmuxNextWakeups
#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextControl
import CmuxNextOracle
#endif

/// The clickable controls hint mode labels (``WindowHintController``): the
/// window's accessibility tree, walked in process, keeps each shown element
/// whose role a person clicks (buttons, rows, tabs, links, fields, menus).
/// A web view's tree lives in its page process, so first-party pages (New
/// Tab, agent chat, Settings) are asked instead: the link hint script lists
/// their clickable elements (``pageTargets(of:clip:deadlines:done:)``). Chromium pages keep
/// their own link hints.
@MainActor
enum WindowHintTargets {
    struct Target: Equatable {
        /// Window coordinates (AppKit, bottom-left origin).
        var rect: CGRect
        var role: String
        var title: String
        /// A web page element: clicked inside its page, not with a window mouse event.
        var page: PageElement?

        var center: NSPoint { NSPoint(x: rect.midX, y: rect.midY) }
        /// The session's key for this target (its labels are per point).
        var point: LinkHintTarget { LinkHintTarget(x: rect.midX, y: rect.midY, left: rect.minX, top: rect.maxY) }
    }

    static let clickable: Set<NSAccessibility.Role> = [
        .button, .checkBox, .radioButton, .popUpButton, .menuButton, .link, .disclosureTriangle,
        .textField, .comboBox, .row, .incrementor, .slider, .colorWell,
    ]
    /// Two letters label 14 * 14 controls; more would need three.
    static let limit = LinkHintSession.alphabet.count * LinkHintSession.alphabet.count
    /// Views whose subtree is another process's (Chromium pages).
    private static let remoteViewNames = ["CEF", "Chromium", "RenderWidgetHost"]
    /// How long the pages may take to list their targets; a busy page is left out.
    static let pageDeadline: Duration = .milliseconds(350)

    /// The native controls in reading order, the shown web views to ask
    /// next, and the content's window rect (targets are clipped to it).
    struct Found {
        var targets: [Target] = []
        var pages: [WKWebView] = []
        var bounds: CGRect = .zero
    }

    static func collect(in content: NSView) -> Found {
        guard let window = content.window else { return Found() }
        let bounds = content.convert(content.bounds, to: nil)
        var found: [Target] = []
        var seen = Set<[Int]>()
        var stack: [Any] = [content]
        var visited = 0
        while let next = stack.popLast(), visited < 5000, found.count < limit {
            visited += 1
            if let view = next as? NSView {
                // visibility-walk-allow: hint mode's accessibility walk (R-vis keeps hit-test and accessibility uses): a hidden view's controls are not clickable
                guard !view.isHiddenOrHasHiddenAncestor, view.alphaValue > 0.01, !isRemote(view) else { continue }
            }
            guard let element = next as? NSAccessibilityProtocol, !element.isAccessibilityHidden() else { continue }
            // Only controls report enabled; custom rows and tabs leave it unset.
            if element.isAccessibilityElement(), let role = element.accessibilityRole(), clickable.contains(role),
               (element as? NSControl)?.isEnabled ?? true {
                // Outside the content the clip is a null rect (infinite origin): left out before the Int key.
                let rect = window.convertFromScreen(element.accessibilityFrame()).intersection(bounds)
                if !rect.isNull, rect.width >= 4, rect.height >= 4,
                   seen.insert([rect.minX, rect.minY, rect.width, rect.height].map { Int($0.rounded()) }).inserted {
                    found.append(Target(rect: rect, role: role.rawValue, title: describe(element)))
                }
            }
            // Children in reverse so the walk pops them in reading order.
            stack.append(contentsOf: (element.accessibilityChildren() ?? []).reversed())
        }
        return Found(targets: found, pages: webViews(in: content), bounds: bounds)
    }

    /// A web view: its tree lives in its page process (WebKit's, Chromium's).
    static func isRemote(_ view: NSView) -> Bool {
        if view is WKWebView { return true }
        let name = NSStringFromClass(type(of: view))
        return remoteViewNames.contains(where: name.contains)
    }

    /// The shown web views under `view`, in subview order (the spare New
    /// Tab page parks under an alpha-0 view: not shown).
    private static func webViews(in view: NSView) -> [WKWebView] {
        guard !view.isHidden, view.alphaValue > 0.01 else { return [] }
        if let page = view as? WKWebView { return page.bounds.width > 0 && page.bounds.height > 0 ? [page] : [] }
        return view.subviews.flatMap(webViews(in:))
    }

    /// The clickable elements of `pages`, in window coordinates and page
    /// order, from the link hint script (isolated from the page's own
    /// scripts), handed to `done` once. Pages that have not answered by ``pageDeadline`` are left out.
    ///
    /// - Parameters:
    ///   - pages: The shown web views (``Found/pages``).
    ///   - clip: The content's window rect.
    ///   - deadlines: The app's one deadline scheduler: the person waits for the labels, so the deadline is a
    ///     `userBlocking` ``MainDeadline``.
    ///   - done: The targets of the pages that answered; called once, unless the query is cancelled first.
    /// - Returns: The query; ``PageCollection/cancel()`` drops its answer.
    @discardableResult
    static func pageTargets(of pages: [WKWebView], clip: CGRect, deadlines: MainDeadlineScheduler,
                            done: @escaping @MainActor ([Target]) -> Void) -> PageCollection {
        let query = PageCollection(count: pages.count, within: pageDeadline, deadlines: deadlines, done: done)
        for (index, page) in pages.enumerated() {
            // task-owner: one page's answer; the query answers once, at its deadline at the latest.
            // main-hop-allow: WKWebView's gesture-free evaluation is main-actor async; the task only starts the page's script for the person's Cmd-J and hands its answer to the query, which the userBlocking deadline bounds
            Task { @MainActor in
                // No user gesture: listing a page's links must not hand it the person's activation.
                let value = try? await WebKitGestureFreeEvaluation(webView: page).evaluate(LinkHintSession.collectScript, in: .defaultClient)
                query.answer(index, targets(value?.stringValue ?? "[]", in: page, clip: clip))
            }
        }
        return query
    }

    /// One page's script result (CSS pixels from its viewport's top left)
    /// in window coordinates.
    private static func targets(_ json: String, in page: WKWebView, clip: CGRect) -> [Target] {
        struct Element: Decodable {
            var x: Double, y: Double, left: Double, top: Double
            var text: String?
        }
        guard let elements = try? JSONDecoder().blockingDecode([Element].self, from: Data(json.utf8)) else { return [] }
        let zoom = page.pageZoom * page.magnification
        func point(_ x: Double, _ y: Double) -> NSPoint {
            let local = NSPoint(x: x * zoom, y: page.isFlipped ? y * zoom : page.bounds.height - y * zoom)
            return page.convert(local, to: nil)
        }
        return elements.compactMap { element in
            // The script gives the top-left corner and the center; the far corner mirrors the first.
            let near = point(element.left, element.top), far = point(2 * element.x - element.left, 2 * element.y - element.top)
            let rect = CGRect(x: min(near.x, far.x), y: min(near.y, far.y), width: abs(far.x - near.x),
                              height: abs(far.y - near.y)).intersection(clip)
            guard rect.width >= 4, rect.height >= 4 else { return nil }
            return Target(rect: rect, role: "web", title: element.text ?? "",
                          page: PageElement(webView: page, x: element.x, y: element.y))
        }
    }

    /// The element's name: its title, label or value, else the first text
    /// under it (a row names itself by its cells).
    private static func describe(_ element: NSAccessibilityProtocol, depth: Int = 0) -> String {
        for text in [element.accessibilityTitle(), element.accessibilityLabel(), element.accessibilityValue() as? String] {
            if let text, !text.isEmpty { return text }
        }
        guard depth < 3 else { return "" }
        for child in element.accessibilityChildren() ?? [] {
            guard let child = child as? NSAccessibilityProtocol else { continue }
            let text = describe(child, depth: depth + 1)
            if !text.isEmpty { return text }
        }
        return ""
    }
}

/// The pages' answers for ``WindowHintTargets/pageTargets(of:clip:deadlines:done:)``,
/// kept in page order, and the one call of its `done`.
@MainActor
final class PageCollection {
    /// Ends the wait for pages that have not answered (``WindowHintTargets/pageDeadline``): the person waits
    /// for the labels, so it runs as `userBlocking` work.
    private let deadline: MainDeadline
    private var done: (@MainActor ([WindowHintTargets.Target]) -> Void)?
    private var answers: [[WindowHintTargets.Target]?]

    /// - Parameters:
    ///   - count: How many pages answer (``answer(_:_:)``); none answers at once.
    ///   - within: How long the pages may take; the answers so far go to `done` then.
    ///   - deadlines: The app's one deadline scheduler.
    ///   - done: The answers in page order, called once unless ``cancel()`` comes first.
    init(count: Int, within: Duration, deadlines: MainDeadlineScheduler,
         done: @escaping @MainActor ([WindowHintTargets.Target]) -> Void) {
        answers = Array(repeating: nil, count: count)
        deadline = MainDeadline(owner: "WindowHintTargets.pageDeadline", workClass: .userBlocking, scheduler: deadlines)
        self.done = done
        guard count > 0 else {
            finish()
            return
        }
        // Answering twice is guarded here: finish cancels the deadline and drops `done`.
        deadline.schedule(after: within) { [weak self] in self?.finish() }
    }

    func answer(_ index: Int, _ targets: [WindowHintTargets.Target]) {
        answers[index] = targets
        if answers.allSatisfy({ $0 != nil }) { finish() }
    }

    /// Hands the answers so far to `done`, once.
    func finish() {
        deadline.cancel()
        guard let done else { return }
        self.done = nil
        done(answers.compactMap { $0 }.flatMap { $0 })
    }

    /// Drops the query: `done` is not called and the deadline goes.
    func cancel() {
        deadline.cancel()
        done = nil
    }
}

/// One first-party page element hint mode labels, clicked inside its page:
/// a web view drops the first click of a window that is not key, and a
/// page element needs no mouse position. Equal by identity.
@MainActor
final class PageElement: Equatable {
    private weak var webView: WKWebView?
    /// CSS pixels in the page's viewport.
    private let x: Double, y: Double

    init(webView: WKWebView, x: Double, y: Double) {
        self.webView = webView
        self.x = x
        self.y = y
    }

    nonisolated static func == (lhs: PageElement, rhs: PageElement) -> Bool { lhs === rhs }

    /// Focuses and clicks the element at the point, as a click does; `menu`
    /// asks it for its context menu instead. The page takes the keyboard.
    func click(menu: Bool) {
        guard let webView else { return }
        if !menu { webView.window?.makeFirstResponder(webView) }
        // Fire and forget: the page clicks in its own process; nothing waits on the answer.
        webView.callAsyncJavaScript(Self.clickScript, arguments: ["x": x, "y": y, "menu": menu], in: nil, in: .defaultClient,
                                    completionHandler: nil)
    }

    private static let clickScript = """
        const hit = document.elementFromPoint(x, y);
        if (!hit) return false;
        const element = hit.closest('a,button,input,select,textarea,summary,label,[role],[onclick],[tabindex],[contenteditable]') || hit;
        if (menu) {
          return element.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 2 }));
        }
        if (typeof element.focus === 'function') element.focus();
        element.click();
        return true;
        """
}

#if DEBUG || CMUX_BENCH_HOOKS
/// The oracle's `ax` facet (``OracleAccessibilityFacet``) over the shown tree hint mode walks.
extension WindowHintTargets {
    /// The `ax` walk: the roles hint mode labels, text areas and menu items, with hint mode's page rule.
    static var oracleWalk: OracleAccessibilityWalk {
        OracleAccessibilityWalk(roles: Set(clickable.union([.textArea, .menuItem]).map(\.rawValue))) { isRemote($0) }
    }

    /// The app's provider over `windows`' windows; the string tables are read on `work`'s files lane.
    static func oracleAccessibilityFacet(windows: WindowManager, work: BackgroundWork) -> OracleAccessibilityFacet {
        let walk = oracleWalk
        return OracleAccessibilityFacet { [weak windows] () throws(OracleFacetError) -> [OracleAccessibilityFacet.Window] in
            guard let windows else { throw OracleFacetError("the window manager is gone") }
            var read: [OracleAccessibilityFacet.Window] = []
            for controller in windows.controllers {
                guard let window = controller.window else { continue }
                read.append(.init(id: ControlWindowInfo.publicID(forKey: controller.state.id), nodes: try walk.nodes(in: window)))
            }
            return read
        } index: { () async throws(OracleFacetError) -> OracleAccessibilityFacet.StringIndex in
            do {
                return try await work.run(.userBlocking, mayBlock: .files) {
                    try OracleAccessibilityFacet.StringIndex(OracleAccessibilityFacet.StringTable.bundleTables())
                }
            } catch let error as OracleFacetError {
                throw error
            } catch {
                throw OracleFacetError("the string tables could not be read: \(error)")
            }
        }
    }
}
#endif
