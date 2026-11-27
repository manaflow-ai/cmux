public import CmuxNextControl
public import CmuxNextSettings
public import AppKit
import UniformTypeIdentifiers

/// `agent.chat.page.query` and `agent.chat.page.screenshot` on the app control socket (`cmux app chat
/// page --tab <tab> query|screenshot`, every build, Release and Nightly too): what a conversation tab's
/// chat page shows, read without a person at the screen. `cmux browser <tab> eval` refuses a chat tab
/// (it is not a browser tab) and Computer Use sees nothing while the Mac is locked; these read the
/// page itself, so they work behind other windows and on a locked Mac.
///
/// Read-only, and they keep a chat's words off automation as the window capture does
/// (``ScreenshotMask``): the query's text, labels and `data-*` values are masked for secrets by
/// the CLI (`acpmux::secret_scan::mask`, as `cmux agents chat read` masks), and the screenshot greys
/// every text run, image, canvas, video, frame and field before its pixels leave the app, so it shows
/// layout, colors and which controls show, never words. They never focus, select, show or thaw the tab:
/// a frozen page is refused, as `agent.chat.perf` refuses it. The App only finds the tab's existing page.
public struct AgentChatPageControl: Sendable {
    public nonisolated static let queryMethod = "agent.chat.page.query"
    public nonisolated static let screenshotMethod = "agent.chat.page.screenshot"
    /// The most elements a query answers, and its default.
    public nonisolated static let maxLimit = 1000
    public nonisolated static let defaultLimit = 200
    /// The most computed-style properties a query reads per element.
    public nonisolated static let maxStyles = 64
    /// The most areas the screenshot greys; a page with more is refused rather than half masked.
    public nonisolated static let maxMaskRects = 50_000
    /// How often the screenshot measures, captures and measures again before it gives up on a page
    /// that keeps moving.
    nonisolated static let attempts = 3

    let find: @MainActor @Sendable (String) -> AgentChatPerfControl.ChatPage

    public init(find: @escaping @MainActor @Sendable (String) -> AgentChatPerfControl.ChatPage) {
        self.find = find
    }

    /// Both methods; the App's control service registers them (`AppControl`).
    public func controlMethods() -> [ControlMethod] {
        let find = find
        return [
            .async(Self.queryMethod) { call in try await Self.query(call.params, find: find) }
                .withDeadline(.fixed(.seconds(15))),
            .async(Self.screenshotMethod) { call in try await Self.screenshot(call.params, find: find) }
                .withDeadline(.fixed(.seconds(30))),
        ]
    }

    // MARK: Query

    /// Every element matching `selector` (document order, the first `limit`): tag, `data-*`,
    /// classes, the first 200 characters of its text as drawn with the whole `length` when longer,
    /// `role`, accessible `label`, its rect in CSS pixels, whether it is in the viewport, and the
    /// computed `styles` asked for. An invalid selector answers `{error: "selector"}`.
    static let queryScript = """
    let all;
    try { all = [...document.querySelectorAll(selector)]; } catch (error) { return JSON.stringify({ error: "selector" }); }
    const props = Array.isArray(styles) ? styles : [];
    const elements = all.slice(0, limit).map((el) => {
      const whole = el.innerText || el.textContent || '';
      const r = el.getBoundingClientRect();
      const item = { tag: el.tagName.toLowerCase(), data: Object.assign({}, el.dataset), classes: [...el.classList],
        text: whole.slice(0, 200), rect: { x: r.x, y: r.y, width: r.width, height: r.height },
        visible: r.width > 0 && r.height > 0 && r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth };
      if (whole.length > 200) item.length = whole.length;
      const role = el.getAttribute('role');
      if (role) item.role = role;
      const named = (el.getAttribute('aria-labelledby') || '').split(/\\s+/).filter(Boolean)
        .map((id) => (document.getElementById(id)?.textContent || '').trim()).filter(Boolean).join(' ');
      const label = (el.getAttribute('aria-label') || '').trim() || named;
      if (label) item.label = label;
      if (props.length) {
        const computed = getComputedStyle(el);
        item.style = Object.fromEntries(props.map((p) => [p, computed.getPropertyValue(p)]));
      }
      return item;
    });
    return JSON.stringify({ count: all.length, elements, viewport: { width: innerWidth, height: innerHeight } });
    """

    @MainActor
    static func query(_ params: [String: JSONValue], find: @MainActor @Sendable (String) -> AgentChatPerfControl.ChatPage) async throws -> JSONValue {
        let selector = params["selector"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "*"
        let limit = try limit(params)
        let styles = try styles(params)
        let (tabID, view) = try page(params, find: find)
        let result = try await view.callPageScript(queryScript, arguments: ["selector": selector, "limit": limit, "styles": styles])
        guard let text = result as? String, case .object(var answer)? = try? JSONValue.parse(Data(text.utf8)) else {
            throw ControlError(code: "unavailable", message: Text.unreadable)
        }
        if answer["error"] != nil { throw ControlError.invalidParams(Text.selector) }
        answer["tab"] = .string(tabID)
        answer["truncated"] = .bool((answer["count"]?.doubleValue ?? 0) > Double(limit))
        return .object(answer)
    }

    /// `limit`, checked: a whole number from 1 to ``maxLimit``, or absent for the default.
    public nonisolated static func limit(_ params: [String: JSONValue]) throws -> Int {
        guard let raw = params["limit"] else { return defaultLimit }
        guard let value = raw.doubleValue, value.rounded() == value, value >= 1, value <= Double(maxLimit) else {
            throw ControlError.invalidParams(String(format: Text.limit, maxLimit))
        }
        return Int(value)
    }

    /// `styles`: CSS property names (`opacity`, `--token`), at most ``maxStyles``.
    public nonisolated static func styles(_ params: [String: JSONValue]) throws -> [String] {
        guard let raw = params["styles"] else { return [] }
        guard case .array(let items) = raw, items.count <= maxStyles else { throw ControlError.invalidParams(Text.styles) }
        return try items.map { item in
            guard let name = item.stringValue, !name.isEmpty, name.count <= 128,
                  name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { throw ControlError.invalidParams(Text.styles) }
            return name
        }
    }

    // MARK: Screenshot

    /// The viewport's size and every area that can show words or pictures, in CSS pixels: each
    /// text run's line boxes, every image, canvas, video, frame, embedded object and field, and any
    /// element with a shadow root whole (its text is out of the walker's reach).
    static let maskScript = """
    const rects = [];
    const add = (r) => {
      if (r.width > 0 && r.height > 0 && r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth)
        rects.push([Math.floor(r.x) - 1, Math.floor(r.y) - 1, Math.ceil(r.width) + 2, Math.ceil(r.height) + 2]);
    };
    const root = document.body || document.documentElement;
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    const range = document.createRange();
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      if (!node.data.trim()) continue;
      range.selectNodeContents(node);
      for (const r of range.getClientRects()) add(r);
    }
    for (const el of document.querySelectorAll('img,picture,canvas,video,iframe,embed,object,input,textarea,select,[contenteditable]'))
      add(el.getBoundingClientRect());
    for (const el of document.querySelectorAll('*')) if (el.shadowRoot) add(el.getBoundingClientRect());
    return JSON.stringify({ width: innerWidth, height: innerHeight, rects });
    """

    /// What ``maskScript`` measured.
    public struct Mask: Equatable, Sendable {
        public var width: Double
        public var height: Double
        public var rects: [CGRect]

        public init?(_ result: Any?) {
            guard let text = result as? String, case .object(let members)? = try? JSONValue.parse(Data(text.utf8)),
                  let width = members["width"]?.doubleValue, let height = members["height"]?.doubleValue, width > 0, height > 0,
                  case .array(let items)? = members["rects"] else { return nil }
            var rects: [CGRect] = []
            rects.reserveCapacity(items.count)
            for item in items {
                guard case .array(let numbers) = item, numbers.count == 4 else { return nil }
                let values = numbers.compactMap(\.doubleValue)
                guard values.count == 4 else { return nil }
                rects.append(CGRect(x: values[0], y: values[1], width: values[2], height: values[3]))
            }
            self.width = width
            self.height = height
            self.rects = rects
        }

        public init(width: Double, height: Double, rects: [CGRect]) {
            self.width = width
            self.height = height
            self.rects = rects
        }
    }

    @MainActor
    static func screenshot(_ params: [String: JSONValue], find: @MainActor @Sendable (String) -> AgentChatPerfControl.ChatPage) async throws -> JSONValue {
        let (tabID, view) = try page(params, find: find)
        for _ in 0..<attempts {
            // Measured before and after the picture: a page that moved in between could show words
            // outside the areas, so only a capture both readings agree on is masked and returned.
            guard let before = Mask(try await view.callPageScript(maskScript)) else { throw ControlError(code: "unavailable", message: Text.unreadable) }
            guard before.rects.count <= maxMaskRects else { throw ControlError(code: "unavailable", message: Text.unsettled) }
            guard let image = await view.pageSnapshot()?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw ControlError(code: "unavailable", message: Text.unreadable)
            }
            guard let after = Mask(try await view.callPageScript(maskScript)) else { throw ControlError(code: "unavailable", message: Text.unreadable) }
            guard before == after else { continue }
            guard let masked = masked(image, by: after), let png = png(masked) else { throw ControlError(code: "unavailable", message: Text.unreadable) }
            return .object([
                "tab": .string(tabID),
                "png_base64": .string(png.base64EncodedString()),
                "width": .number(Double(masked.width)),
                "height": .number(Double(masked.height)),
                "masked": .number(Double(after.rects.count)),
                "masked_areas": .array([.string("text"), .string("media")]),
            ])
        }
        throw ControlError(code: "unavailable", message: Text.unsettled)
    }

    /// `image` with `mask`'s areas filled grey, its CSS pixels scaled to the picture's pixels; nil
    /// when it cannot be drawn (then nothing is returned).
    public nonisolated static func masked(_ image: CGImage, by mask: Mask) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: full)
        let scaleX = Double(width) / mask.width
        let scaleY = Double(height) / mask.height
        context.setFillColor(CGColor(gray: 0.5, alpha: 1)) // colour-allow: the masked screenshot's redaction fill, painted into a picture file, not the app's UI, so no theme ink applies
        for rect in mask.rects {
            // CSS y grows down; the bitmap's grows up.
            let cut = CGRect(x: rect.minX * scaleX, y: Double(height) - rect.maxY * scaleY,
                             width: rect.width * scaleX, height: rect.height * scaleY).integral.intersection(full)
            if !cut.isEmpty { context.fill(cut) }
        }
        return context.makeImage()
    }

    nonisolated static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    // MARK: Shared

    /// The tab's loaded, awake chat page, found without focusing, showing or thawing anything.
    @MainActor
    static func page(_ params: [String: JSONValue], find: @MainActor @Sendable (String) -> AgentChatPerfControl.ChatPage) throws -> (String, AgentPaneView) {
        guard let raw = params["tab"]?.stringValue, !raw.isEmpty else { throw ControlError.invalidParams(Text.needsTab) }
        let tabID = normalizedControlTabID(raw)
        switch find(tabID) {
        case .missing: throw ControlError(code: "not_found", message: AgentChatPerfControl.Text.noTab)
        case .notAgentChat: throw ControlError.invalidParams(AgentChatPerfControl.Text.notAgentChat)
        case .notLoaded: throw ControlError(code: "unavailable", message: Text.pageNotLoaded)
        case .page(let view):
            // Any call would thaw a frozen page first; reading must not wake it.
            guard !view.pageIsFrozen else { throw ControlError(code: "unavailable", message: Text.pageAsleep) }
            return (tabID, view)
        }
    }

    /// The refusals, in this package's Localizable.xcstrings (`agentPane.chatPage.*`).
    nonisolated enum Text {
        static var needsTab: String { String(localized: "agentPane.chatPage.needsTab", defaultValue: "Name the chat tab to read.", bundle: .localizedModule) }
        static var pageNotLoaded: String {
            String(localized: "agentPane.chatPage.pageNotLoaded", defaultValue: "That chat's page isn't loaded. Open the chat once, then read it again.", bundle: .localizedModule)
        }
        static var pageAsleep: String {
            String(
                localized: "agentPane.chatPage.pageAsleep",
                defaultValue: "That chat's page is asleep while it's hidden, and reading doesn't wake it. Show the chat, then read it again.",
                bundle: .localizedModule)
        }
        static var limit: String { String(localized: "agentPane.chatPage.limit", defaultValue: "limit must be a whole number from 1 to %lld", bundle: .localizedModule) }
        static var styles: String {
            String(localized: "agentPane.chatPage.styles", defaultValue: "styles must be a list of at most 64 CSS property names.", bundle: .localizedModule)
        }
        static var selector: String { String(localized: "agentPane.chatPage.selector", defaultValue: "That selector isn't valid CSS.", bundle: .localizedModule) }
        static var unreadable: String {
            String(localized: "agentPane.chatPage.unreadable", defaultValue: "That chat's page couldn't be read. Try again.", bundle: .localizedModule)
        }
        static var unsettled: String {
            String(localized: "agentPane.chatPage.unsettled", defaultValue: "That chat kept changing while it was captured. Try again when it settles.", bundle: .localizedModule)
        }
    }
}
