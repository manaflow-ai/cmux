#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextDesign
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
    /// The app's made-ahead file picker, for each fixture's "+".
    private let openPanel: MadeAheadOpenPanel

    init(openPanel: MadeAheadOpenPanel) {
        self.openPanel = openPanel
    }
    /// The open fixture whose transcript is `view`.
    func fixture(showing view: HomeNativeTranscriptView) -> HomeNativeFixture? { fixtures.values.first { $0.shows(view) } }
    /// The next page shows the attachment fixture (`{"attachments": true}`).
    var nextAttachments = false

    var page: InternalPageID { .homeNativeFixture }
    var title: String { HomeNativeFixture.title }
    var symbol: String { "bubble.left.and.bubble.right" }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        let fixture = HomeNativeFixture(attachments: nextAttachments, openPanel: openPanel)
        nextAttachments = false
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
    /// | menu | geometry | link | texts | typing | rows | resize | nudge | list | presence | faces, text, dx, dy, trims, mine, tab, prefix, limit}: drives the shown Home through its own entry points (the
    /// field's text system, Return's send, the tapback picker's react, the
    /// scroll view) for screenshots and recordings on a window that is
    /// never key. `tab` (a key from `debug.home` page.tabs) drives that Home tab.
    static func drive(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        if params["action"]?.stringValue == "list" { return DebugHome.driveDockList(params, services: services) }
        if params["action"]?.stringValue == "legacy_pins" { return DebugHome.legacyPins(params, services: services) }
        if params["action"]?.stringValue == "permalink" { return permalink(params, services: services) }
        let view: HomeNativeTranscriptView?
        if let tab = params["tab"]?.stringValue {
            view = (services.pages.provider(.homeTab) as? HomePageTab)?.tabs.first { $0.key == tab }?.view.host
                .flatMap(HomePageTab.transcript(in:))
        } else {
            // `window`: the Home view shown in that window (default: the active window's).
            let id = params["window"]?.stringValue, window = id.flatMap { services.windows.controller(for: $0)?.window }
            if let id, window == nil { return .object(["error": .string("no window \(id)")]) }
            view = HomeNativeTranscriptView.shown(in: window ?? services.windows.active?.window)
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
            // with the HomeStore transcript and the owner's snapshot (a message in both but not here is hidden); a stream (ask 11) last.
            let texts = view.debugMessageTexts(limit: params["limit"]?.intValue ?? 50) + view.debugStreamTexts
            return .object(["ok": .bool(true), "texts": .array(texts.map { .string($0) }),
                            "statusLine": view.debugStatusLine.map { .string($0) } ?? .null, "rebuilds": .number(Double(view.debugRebuilds)), "streams": .number(Double(view.debugStreamTexts.count)), "lineCloseAfterHandOffFires": view.debugLineCloseAfterHandOffFires.map { .number(Double($0)) } ?? .null])
        case "engine_set", "chief_control":
            // One pick in the shown conversation's Chief settings panel (`key`: harness, model or effort;
            // no `value`: default), as its popup does (scripts/cmux-next/chief-home-fixes-live.py).
            // "chief_control": the named Chief the shown view's controls name (null: the default Chief).
            guard let host = sequence(first: view as NSView, next: \.superview).lazy.compactMap({ $0 as? HomeHostView }).first else {
                return .object(["error": .string("no Home host view")])
            }
            if params["action"]?.stringValue == "chief_control" {
                return .object(["ok": .bool(true), "named": host.debugNamedChief.map { .string($0) } ?? .null])
            }
            guard let key = params["key"]?.stringValue else { return .object(["error": .string("engine_set needs key")]) }
            host.debugPickEngine(key, params["value"]?.stringValue)
            ok = true
        case "stream":
            // The fixture's Chief streams `text` (its whole reply so far); `done` posts it (home-width-sweep.py).
            guard let fixture = (services.pages.provider(.homeNativeFixture) as? DebugHomeNativeFixture)?.fixture(showing: view) else {
                return .object(["error": .string("stream needs the Home fixture (debug.home_native_fixture.open)")])
            }
            ok = fixture.debugStream(params["text"]?.stringValue ?? "", done: params["done"]?.boolValue ?? false)
        case "presence":
            // Who else has the fixture's conversation open (`people`: mock participant ids, default
            // three of the mock's people; `typing`: one of them types), as the owner's presence.
            guard let fixture = (services.pages.provider(.homeNativeFixture) as? DebugHomeNativeFixture)?.fixture(showing: view) else {
                return .object(["error": .string("presence needs the native Home fixture (debug.home_native_fixture.open)")])
            }
            let people = params["people"]?.arrayValue?.compactMap(\.stringValue) ?? HomeNativeFixture.presencePeople
            ok = fixture.debugPresence(people, typing: params["typing"]?.stringValue)
        case "faces":
            // The header's faces as drawn: each initial, and whether they show.
            let drawn = view.debugHeaderFaces
            return .object(["ok": .bool(true), "initials": .array(drawn.initials.map { .string($0) }), "shown": .bool(drawn.shown)])
        case "focus": ok = view.window?.makeFirstResponder(view.primaryInput) ?? false
        case "type":
            guard let field = view.primaryInput as? NSTextView else { return .object(["error": .string("no field")]) }
            field.insertText(params["text"]?.stringValue ?? "", replacementRange: field.selectedRange())
            ok = true
        case "send":
            // A refused send is never ok: a test cannot pass on a dropped send (cx-ebm.55).
            if let refusal = view.sendDraft() { return .object(["ok": .bool(false), "refused": .string(refusal)]) }
            ok = true
        case "thread", "escape":
            // "thread": a click on the newest "N Replies" or thread preview; "escape": Esc in the field.
            // Both answer with the open thread's root (null: no thread is open).
            if params["action"]?.stringValue == "thread" { _ = view.debugOpenNewestThread() } else { view.debugEscape() }
            return treeReply(view, ok: true)
        case "reply", "post_escape", "thread_state":
            // "reply": Reply… in the newest text bubble's menu; "post_escape": a real Esc key press
            // (`outside`: the key focus on the window, not the pane); "thread_state": no input.
            switch params["action"]?.stringValue {
            case "reply": _ = view.debugReplyNewest(mine: params["mine"]?.boolValue ?? false)
            case "post_escape": view.debugPostEscape(outside: params["outside"]?.boolValue ?? false)
            default: break
            }
            return treeReply(view, ok: true)
        case "reply_text", "branch":
            // Tree threads: Reply… on the bubble whose text is `text`, or a click on "N Replies" under it.
            let text = params["text"]?.stringValue ?? ""
            return treeReply(view, ok: (params["action"]?.stringValue == "branch" ? view.debugOpenBranch(text: text) : view.debugReply(text: text)) != nil)
        case "tapback": ok = view.debugTapbackNewestIncoming(mine: params["mine"]?.boolValue ?? false)
        case "video": ok = view.debugToggleNewestVideo()
        case "scroll": view.debugScroll(by: CGFloat(params["dy"]?.doubleValue ?? -400)); ok = true
        default:
            if let out = view.debugTreeDrive(params["action"]?.stringValue ?? "", params.compactMapValues(\.stringValue)) { return .object(out.mapValues { .string($0) }) }
            return .object(["error": .string("action must be focus, type, send, stream, tapback, video, scroll, menu, geometry, link, texts, typing, nudge, thread, escape, reply, post_escape, thread_state, reply_text, branch or permalink")])
        }
        return .object(["ok": .bool(ok)])
    }

    /// Tree threads: `ok`, the open thread (transcript id), the drill path and shown message (owner ids).
    static func treeReply(_ view: HomeNativeTranscriptView, ok: Bool) -> JSONValue {
        let s: (String?) -> JSONValue = { $0.map { .string($0) } ?? .null }
        return .object(["ok": .bool(ok), "open_thread": s(view.openThreadRoot), "thread_path": .array(view.debugOpenThreadPath.map(s)), "thread_message": s(view.openThreadMessage)])
    }
    /// `permalink {url}`: opens a message link as the docked Home's hand-off does.
    static func permalink(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        guard let link = HomeDockSelection(link: params["url"]?.stringValue ?? "") else { return .object(["error": .string("not a link")]) }
        if !services.home.dock.isClassic, let dock = HomeDockTab.view(services) { dock.open(link) } else { (services.windows.active?.topPages.views[.home] as? TopHomePageView)?.show(link) }
        return .object(["ok": .bool(true)])
    }

    static func open(services: AppServices, attachments: Bool = false, fresh: Bool = false) -> JSONValue {
        if services.pages.provider(.homeNativeFixture) == nil { services.pages.register(DebugHomeNativeFixture(openPanel: services.openPanel)) }
        (services.pages.provider(.homeNativeFixture) as? DebugHomeNativeFixture)?.nextAttachments = attachments
        let view = fresh ? services.pages.openNew(.homeNativeFixture, in: services.windows.active, focus: true)
            : services.pages.show(.homeNativeFixture, in: services.windows.active, focus: true)
        return .object(["ok": .bool(view != nil), "page": .string(InternalPageID.homeNativeFixture.rawValue)])
    }
}
#endif
