#if DEBUG
import AppKit
import CmuxNextHome
import CmuxNextSettings

/// DEBUG ONLY: `debug.home_native_fixture.open` opens the native Home
/// transcript (`HomeNativeTranscriptView`) over the mock owner's fixture
/// data as an internal page tab of the active window, for screenshots
/// (`debug.window_snapshot`) and dogfood before the real Home wiring.
/// Compiled out of Release with this whole file.
extension InternalPageID {
    static let homeNativeFixture = InternalPageID(rawValue: "home-native-fixture")
}

@MainActor
final class DebugHomeNativeFixture: InternalPageProvider {
    private var fixtures: [String: HomeNativeFixture] = [:]
    /// The next page shows the attachment fixture (`{"attachments": true}`).
    var nextAttachments = false
    /// The next page ends the Chief's history with its Markdown and a link card (`{"showcase": false}`: not).
    var nextShowcase = true

    var page: InternalPageID { .homeNativeFixture }
    var title: String { HomeNativeFixture.title }

    /// The URLs the open fixtures' clicks would have opened in another app (blocked, never opened).
    var blockedOpens: [String] { fixtures.values.flatMap(\.blockedOpens) }

    /// Streams a Chief reply into every open fixture (`HomeNativeFixture.startStream`).
    func startStream() -> Bool {
        fixtures.values.map { $0.startStream() }.contains(true)
    }
    var symbol: String { "bubble.left.and.bubble.right" }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        let fixture = HomeNativeFixture(attachments: nextAttachments, showcase: nextShowcase)
        nextAttachments = false
        nextShowcase = true
        fixtures[key] = fixture
        return fixture.container
    }

    func tabClosed(_ key: String) {
        fixtures.removeValue(forKey: key)?.close()
    }

    /// `debug.home.attach`: the shown Home composer of the active window
    /// (the real Home tab or this fixture) takes the files by path.
    static func attach(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let paths = params["paths"]?.arrayValue?.compactMap(\.stringValue) ?? params["path"]?.stringValue.map { [$0] } ?? []
        guard let via = HomeAttachVia(rawValue: params["via"]?.stringValue ?? "drop") else {
            return .object(["error": .string("via must be drop, paste or pick")])
        }
        guard let view = HomeNativeTranscriptView.shown(in: services.windows.active?.window) else {
            return .object(["error": .string("no Home conversation is shown")])
        }
        let result = view.attachFiles(paths: paths, via: via)
        return .object(["ok": .bool(result == .accepted), "result": .string(result.rawValue), "via": .string(via.rawValue)])
    }

    /// `debug.home.drive` {action: focus | type | send | tapback | video | scroll
    /// | menu | geometry | link | texts | typing | rows | resize | nudge, text, dx, dy, trims, mine, tab, prefix, limit}: drives the shown Home through its own entry points (the
    /// field's text system, Return's send, the tapback picker's react, the
    /// scroll view) for screenshots and recordings on a window that is
    /// never key. `tab` (a key from `debug.home` page.tabs) drives that Home tab.
    static func drive(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let view: HomeNativeTranscriptView?
        if let tab = params["tab"]?.stringValue {
            view = (services.pages.provider(.homeTab) as? HomePageTab)?.tabs.first { $0.key == tab }?.view.host
                .flatMap(HomePageTab.transcript(in:))
        } else {
            view = HomeNativeTranscriptView.shown(in: services.windows.active?.window)
        }
        guard let view else {
            return .object(["error": .string("no Home conversation is shown")])
        }
        let ok: Bool
        switch params["action"]?.stringValue ?? "" {
        case "menu":
            let titles = view.debugMenuTitles(mine: params["mine"]?.boolValue ?? false) ?? []
            return .object(["ok": .bool(!titles.isEmpty), "items": .array(titles.map { .string($0) })])
        case "link":
            // A click on the first shown link with this prefix (a Chief subagent's `cmux://chief/`).
            let url = view.debugClickLink(prefix: params["prefix"]?.stringValue ?? "https://")
            return .object(["ok": .bool(url != nil), "url": url.map { .string($0) } ?? .null])
        case "typing":
            // The typing bubble's body in window points (bottom-left origin) and the window's size,
            // for a pixel check of a window snapshot (scripts/cmux-next/home-typing-still.py).
            guard let r = view.debugTypingBubbleFrame(), let size = view.window?.frame.size else {
                return .object(["ok": .bool(false), "error": .string("no typing row shows")])
            }
            let o = view.debugHostOrigin
            return .object(["ok": .bool(true), "x": .number(Double(r.minX)), "y": .number(Double(r.minY)), "width": .number(Double(r.width)),
                            "height": .number(Double(r.height)), "windowWidth": .number(Double(size.width)), "windowHeight": .number(Double(size.height)),
                            "hostX": .number(Double(o.x)), "hostY": .number(Double(o.y))])
        case "rows":
            // The visible rows as drawn, in window points (bottom-left origin), top to bottom, and the
            // window's size: the half-point pixel check of message rows (home-typing-still.py, home-hidden-messages.py).
            guard let size = view.window?.frame.size else { return .object(["ok": .bool(false), "error": .string("no window")]) }
            let o = view.debugHostOrigin
            let rows: [JSONValue] = view.debugRowFrames().map { r in
                .object(["kind": .string(r.kind), "key": .string(r.key), "outgoing": .bool(r.outgoing),
                         "x": .number(Double(r.frame.minX)), "y": .number(Double(r.frame.minY)),
                         "width": .number(Double(r.frame.width)), "height": .number(Double(r.frame.height)),
                         "balloon": .object(["x": .number(Double(r.balloon.minX)), "y": .number(Double(r.balloon.minY)),
                                             "width": .number(Double(r.balloon.width)), "height": .number(Double(r.balloon.height))])])
            }
            return .object(["ok": .bool(!rows.isEmpty), "rows": .array(rows), "windowWidth": .number(Double(size.width)),
                            "scale": .number(Double(view.window?.backingScaleFactor ?? 0)), "trim": .number(Double(view.debugTranscriptWidthTrim)),
                            "hostRight": .number(Double(view.debugHostFrame.maxX)),
                            "windowHeight": .number(Double(size.height)), "hostX": .number(Double(o.x)), "hostY": .number(Double(o.y))])
        case "resize":
            // Width changes in one main-thread turn (one display frame): the pass counters and rows after each.
            let trims = params["trims"]?.arrayValue?.compactMap(\.doubleValue) ?? []
            func rowsJSON() -> JSONValue {
                .array(view.debugRowFrames().map { r in
                    .object(["kind": .string(r.kind), "key": .string(r.key), "outgoing": .bool(r.outgoing),
                             "x": .number(Double(r.balloon.minX)), "maxX": .number(Double(r.balloon.maxX)),
                             "y": .number(Double(r.balloon.minY))])
                })
            }
            var steps: [JSONValue] = []
            for trim in trims {
                // The step's main-thread time (its width pass with the layout it causes), to tell a deferral the
                // frame budget asks for (a pass of 2 ms or more, e.g. a Debug build) from one it does not.
                let t0 = CACurrentMediaTime()
                view.debugTrimWidth(CGFloat(trim))
                let ms = (CACurrentMediaTime() - t0) * 1000
                let c = view.debugWidthPasses
                steps.append(.object(["trim": .number(trim), "passes": .number(Double(c.passes)), "deferred": .number(Double(c.deferred)),
                                      "ms": .number(ms), "rows": rowsJSON()]))
            }
            let c0 = view.debugWidthPasses
            return .object(["ok": .bool(!trims.isEmpty), "steps": .array(steps), "budgetMs": .number(view.debugWidthPassBudget * 1000),
                            "passes": .number(Double(c0.passes)), "deferred": .number(Double(c0.deferred))])
        case "nudge":
            // The transcript moves by dx, dy points in its pane (a pane on a fraction of a point).
            view.debugNudge(dx: CGFloat(params["dx"]?.doubleValue ?? 0.5), dy: CGFloat(params["dy"]?.doubleValue ?? 0))
            ok = true
        case "geometry":
            return .object(["ok": .bool(true), "geometry": .object(view.debugGeometry().mapValues { .number($0) })])
        case "texts":
            // What the transcript view itself holds (its MessagesLab store), oldest first, to compare
            // with the HomeStore transcript and the owner's snapshot (a message in both but not here is hidden).
            let texts = view.debugMessageTexts(limit: params["limit"]?.intValue ?? 50)
            return .object(["ok": .bool(true), "texts": .array(texts.map { .string($0) })])
        case "focus": ok = view.window?.makeFirstResponder(view.primaryInput) ?? false
        case "type":
            guard let field = view.primaryInput as? NSTextView else { return .object(["error": .string("no field")]) }
            field.insertText(params["text"]?.stringValue ?? "", replacementRange: field.selectedRange())
            ok = true
        case "send":
            // A refused send is never ok: a test cannot pass on a dropped send (cx-ebm.55).
            if let refusal = view.sendDraft() { return .object(["ok": .bool(false), "refused": .string(refusal)]) }
            ok = true
        case "thread", "click_replies", "escape":
            // "thread": a click on the newest "N Replies" or thread preview (ChatController.clicked);
            // "click_replies": the same point through the real mouse path (mouseDown and mouseUp);
            // "escape": Esc in the field. All answer with the open thread's root (null: none is open).
            let root: String?
            switch params["action"]?.stringValue {
            case "thread": root = view.debugOpenNewestThread()
            case "click_replies": root = view.debugClickNewestReplies()
            default: view.debugEscape(); root = view.debugOpenThread
            }
            return .object(["ok": .bool(true), "open_thread": root.map { .string($0) } ?? .null])
        case "reply", "post_escape", "key_escape", "thread_state":
            // "reply": Reply… in the newest text bubble's menu; "post_escape": a real Esc key press
            // (`outside`: the key focus on the window, not the pane); "key_escape": Esc dispatched as a
            // key window would (to the focused field, else through the app's local monitors);
            // "thread_state": no input.
            switch params["action"]?.stringValue {
            case "reply": _ = view.debugReplyNewest(mine: params["mine"]?.boolValue ?? false)
            case "post_escape": view.debugPostEscape(outside: params["outside"]?.boolValue ?? false)
            case "key_escape": view.debugKeyEscape()
            default: break
            }
            return .object(["ok": .bool(true), "open_thread": view.debugOpenThread.map { .string($0) } ?? .null])
        case "click":
            // A left click at x, y (window points, bottom-left origin: the space of "rows") through the real mouse path;
            // `count` 2: a double click. `key` (a row key from "rows") clicks that row's body centre where the row
            // is now (a click after a send that moved the rows hits the same bubble). Answers the open thread too.
            let point: CGPoint
            if let key = params["key"]?.stringValue {
                guard let row = view.debugRowFrames().first(where: { $0.key == key }) else { return .object(["error": .string("no shown row \(key)")]) }
                point = CGPoint(x: row.frame.midX, y: row.frame.midY)
            } else if let x = params["x"]?.doubleValue, let y = params["y"]?.doubleValue {
                point = CGPoint(x: x, y: y)
            } else {
                return .object(["error": .string("click needs key, or x and y")])
            }
            let clicked = view.debugClick(atWindow: point, count: params["count"]?.intValue ?? 1)
            return .object(["ok": .bool(clicked), "open_thread": view.debugOpenThread.map { .string($0) } ?? .null])
        case "paste":
            // The main menu's Paste to this window's first responder, as AppKit sends it from a key window
            // (a never-key capture window does not get the menu's action).
            ok = view.debugMenuPaste()
        case "blocked_opens":
            // What the fixture's link and attachment clicks would have opened (the fixture never opens apps).
            let urls = (services.pages.provider(.homeNativeFixture) as? DebugHomeNativeFixture)?.blockedOpens ?? []
            return .object(["ok": .bool(true), "urls": .array(urls.map { .string($0) })])
        case "stream":
            // The fixture's Chief streams a reply in, a word every 120 ms (the mock owner's updates).
            ok = (services.pages.provider(.homeNativeFixture) as? DebugHomeNativeFixture)?.startStream() ?? false
        case "tapback": ok = view.debugTapbackNewestIncoming(mine: params["mine"]?.boolValue ?? false)
        case "video": ok = view.debugToggleNewestVideo()
        case "scroll": view.debugScroll(by: CGFloat(params["dy"]?.doubleValue ?? -400)); ok = true
        default: return .object(["error": .string("action must be focus, type, send, tapback, video, scroll, menu, geometry, link, texts, typing, nudge, thread, escape, reply, post_escape, key_escape, click, click_replies, stream, blocked_opens, paste or thread_state")])
        }
        return .object(["ok": .bool(ok)])
    }

    static func open(services: AppServices, attachments: Bool = false, showcase: Bool = true, fresh: Bool = false) -> JSONValue {
        if services.pages.provider(.homeNativeFixture) == nil { services.pages.register(DebugHomeNativeFixture()) }
        (services.pages.provider(.homeNativeFixture) as? DebugHomeNativeFixture)?.nextAttachments = attachments
        (services.pages.provider(.homeNativeFixture) as? DebugHomeNativeFixture)?.nextShowcase = showcase
        let view = fresh ? services.pages.openNew(.homeNativeFixture, in: services.windows.active, focus: true)
            : services.pages.show(.homeNativeFixture, in: services.windows.active, focus: true)
        return .object(["ok": .bool(view != nil), "page": .string(InternalPageID.homeNativeFixture.rawValue)])
    }
}
#endif
