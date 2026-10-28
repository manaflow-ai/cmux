import AppKit
import CmuxNextBrowser
import WebKit
import CmuxNextWakeups

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
                guard !view.isHiddenOrHasHiddenAncestor, view.alphaValue > 0.01 else { continue }
                guard !(view is WKWebView) else { continue }
                let name = NSStringFromClass(type(of: view))
                guard !remoteViewNames.contains(where: name.contains) else { continue }
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
        guard let elements = try? JSONDecoder().decode([Element].self, from: Data(json.utf8)) else { return [] }
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
