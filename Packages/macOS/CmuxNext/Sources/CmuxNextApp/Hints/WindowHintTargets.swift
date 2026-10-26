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
/// their clickable elements (``pageTargets(of:clip:)``). Chromium pages keep
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
    /// scripts). Pages that have not answered by ``pageDeadline`` are left out.
    static func pageTargets(of pages: [WKWebView], clip: CGRect) async -> [Target] {
        guard !pages.isEmpty else { return [] }
        let collection = PageCollection(count: pages.count)
        return await withCheckedContinuation { continuation in
            collection.continuation = continuation
            for (index, page) in pages.enumerated() {
                // task-owner: one page's answer; the collection resumes once, at the deadline at the latest.
                Task { @MainActor in
                    // No user gesture: listing a page's links must not hand it the person's activation.
                    let value = try? await WebKitGestureFreeEvaluation(webView: page).evaluate(LinkHintSession.collectScript, in: .defaultClient)
                    collection.answer(index, targets(value?.stringValue ?? "[]", in: page, clip: clip))
                }
            }
            // The deadline; resuming twice is guarded by the collection, which cancels it on finish.
            collection.deadline.schedule(after: pageDeadline) { @MainActor in
                collection.finish()
            }
        }
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

/// The pages' answers for ``WindowHintTargets/pageTargets(of:clip:)``,
/// kept in page order, and the one resume of its continuation.
@MainActor
private final class PageCollection {
    var continuation: CheckedContinuation<[WindowHintTargets.Target], Never>?
    let deadline = DemandTimer(owner: "WindowHintTargets.pageDeadline")
    private var answers: [[WindowHintTargets.Target]?]

    init(count: Int) { answers = Array(repeating: nil, count: count) }

    func answer(_ index: Int, _ targets: [WindowHintTargets.Target]) {
        answers[index] = targets
        if answers.allSatisfy({ $0 != nil }) { finish() }
    }

    func finish() {
        deadline.cancel()
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: answers.compactMap { $0 }.flatMap { $0 })
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
        // task-owner: fire-and-forget page click; nothing waits on it.
        Task { _ = try? await webView.callAsyncJavaScript(Self.clickScript, arguments: ["x": x, "y": y, "menu": menu],
                                                          in: nil, contentWorld: .defaultClient) }
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
/// The oracle's `ax` facet's walk (p15-oracle-216, ``OracleAccessibilityFacet``): the shown tree hint mode walks,
/// keeping each element a person can act on and the one with the keyboard focus.
extension WindowHintTargets {
    /// The roles kept besides the focused element: the controls hint mode labels, text areas and menu items.
    static let oracleRoles = clickable.union([.textArea, .menuItem])
    /// More elements than this in one window fails the snapshot rather than recording part of the tree.
    static let oracleLimit = 50_000

    /// The app's provider over `windows`' windows; the keys are read on `work`'s files lane.
    static func oracleAccessibilityFacet(windows: WindowManager, work: BackgroundWork) -> OracleAccessibilityFacet {
        OracleAccessibilityFacet { [weak windows] () throws(OracleFacetError) -> [OracleAccessibilityFacet.Window] in
            guard let windows else { throw OracleFacetError("the window manager is gone") }
            var read: [OracleAccessibilityFacet.Window] = []
            for controller in windows.controllers {
                guard let window = controller.window else { continue }
                read.append(.init(id: ControlWindowInfo.publicID(forKey: controller.state.id), nodes: try oracleNodes(in: window)))
            }
            return read
        } keys: { (names: Set<String>) async throws(OracleFacetError) -> [String: String] in
            do {
                return try await work.run(.userBlocking, mayBlock: .files) { try oracleLabelKeys(names) }
            } catch let error as OracleFacetError {
                throw error
            } catch {
                throw OracleFacetError("the string tables could not be read: \(error)")
            }
        }
    }

    /// The localization keys of `names` in the app's string tables: the main bundle's and those of the package
    /// resource bundles in `resources` (where the app keeps them), each in the localization the bundle shows.
    /// It reads the disk: never on the main thread.
    nonisolated static func oracleLabelKeys(_ names: Set<String>, resources: URL? = Bundle.main.resourceURL) throws -> [String: String] {
        var bundles = [Bundle.main]
        if let resources {
            let found = try FileManager.checked.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
            bundles += found.filter { $0.pathExtension == "bundle" }.compactMap { Bundle(url: $0) }
        }
        var tables: [OracleAccessibilityFacet.StringTable] = []
        for bundle in bundles {
            let urls = bundle.urls(forResourcesWithExtension: "strings", subdirectory: nil,
                                   localization: bundle.preferredLocalizations.first) ?? []
            for url in urls {
                tables.append(.init(name: url.lastPathComponent, data: try Data(blockingContentsOf: url)))
            }
        }
        return try OracleAccessibilityFacet.keys(for: names, in: tables)
    }

    /// `window`'s kept elements in preorder, then those of its sheet and its shown child windows (a panel over it),
    /// each root's children at depth 0. A web view's subtree is its page's (the `webviews` facet); a focused web
    /// view is kept as a leaf, so the focus stays in the tree.
    static func oracleNodes(in window: NSWindow) throws(OracleFacetError) -> [OracleAccessibilityFacet.Node] {
        var roots = [window]
        if let sheet = window.attachedSheet { roots.append(sheet) }
        roots += (window.childWindows ?? []).filter { $0.isVisible }
        var nodes: [OracleAccessibilityFacet.Node] = []
        var visited = 0
        for root in roots {
            let focus = oracleFocusedView(of: root)
            var stack: [(Any, Int)] = (root.accessibilityChildren() ?? []).reversed().map { ($0, 0) }
            while let item = stack.popLast() {
                let (next, depth) = item
                visited += 1
                guard visited <= oracleLimit else {
                    throw OracleFacetError("window \(window.windowNumber) has more than \(oracleLimit) accessibility elements")
                }
                let view = next as? NSView
                // visibility-walk-allow: the AX read keeps only what shows, as an AX client sees it; no work is deferred
                if let view, view.isHiddenOrHasHiddenAncestor || view.alphaValue <= 0.01 { continue }
                guard let element = next as? NSAccessibilityProtocol, !element.isAccessibilityHidden() else { continue }
                let remote = view.map { isRemote($0) } ?? false
                // A page's focus is inside its view's subtree, which the walk leaves to the page.
                let holdsFocus = view.map { remote ? focus?.isDescendant(of: $0) == true : $0 === focus } ?? false
                let focused = holdsFocus || element.isAccessibilityFocused()
                var childDepth = depth
                if let role = element.accessibilityRole(),
                   focused || (element.isAccessibilityElement() && !remote && oracleRoles.contains(role)) {
                    nodes.append(OracleAccessibilityFacet.Node(
                        role: role.rawValue, names: oracleNames(of: element),
                        enabled: (element as? NSControl)?.isEnabled ?? element.isAccessibilityEnabled(), focused: focused, depth: depth))
                    childDepth += 1
                }
                guard !remote else { continue }
                // Children in reverse so the walk pops them in reading order.
                stack.append(contentsOf: (element.accessibilityChildren() ?? []).reversed().map { ($0, childDepth) })
            }
        }
        return nodes
    }

    /// The view with the keyboard focus: the first responder, or the text field a field editor edits for it.
    private static func oracleFocusedView(of window: NSWindow) -> NSView? {
        guard let responder = window.firstResponder as? NSView else { return nil }
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView { return field }
        return responder
    }

    /// The texts that name `element`, in the order the facet tries them for a localization key.
    private static func oracleNames(of element: NSAccessibilityProtocol) -> [String] {
        let texts: [String?] = [element.accessibilityLabel(), element.accessibilityTitle(), element.accessibilityPlaceholderValue(),
                                element.accessibilityHelp()]
        return texts.compactMap { $0 }.filter { !$0.isEmpty }
    }
}
#endif
