import AppKit
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import JavaScriptCore
import Testing
@testable import CmuxNextAgentPane

/// Session Info drawn by the App (AgentPaneSessionInfo.swift, AgentPaneView+SessionInfo.swift): the
/// page's model makes, updates and removes the floating panel, the panel runs the pane's full height,
/// and its clicks go back to the page.
@Suite(.serialized, .closesItsWindows)
@MainActor
struct AgentPaneNativeSessionInfoTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static func enableNative() {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register([AgentPaneTunables.nativeSessionInfo.descriptor])
        TunableStore.shared.set(AgentPaneTunables.nativeSessionInfo.key, .bool(true))
    }

    @Test func pageDrawsSessionInfoByDefault() {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register([AgentPaneTunables.nativeSessionInfo.descriptor])
        TunableStore.shared.set(AgentPaneTunables.nativeSessionInfo.key, nil)
        defer { TunableStore.shared.set(AgentPaneTunables.nativeSessionInfo.key, nil) }
        #expect(AgentPaneTunables.nativeSessionInfo.descriptor.defaultValue == .bool(false))
        #expect(!AgentPaneTunables.nativeSessionInfo.value)
    }

    private static func info(open: Bool = true, width: Double = 320, top: Double = 28, side: Double = 0,
                             foot: Double? = nil) -> [String: Any] {
        var info: [String: Any] = [
            "open": open, "width": width, "top": top, "side": side, "label": "Session Info",
            "sections": [[
                "id": "subagents", "group": "running", "title": "Subagents", "meta": "1 running",
                "open": true, "foldable": true,
                "rows": [["id": "a1", "title": "rail-fix", "tone": "running", "action": "subagents.open:a1",
                          "buttons": [["label": "Stop", "action": "subagents.stop:a1"]]]],
            ]],
        ]
        if let foot { info["foot"] = foot }
        return info
    }

    private static func model(_ info: [String: Any]) throws -> AgentPaneSessionInfoModel {
        try #require(AgentPaneSessionInfoModel.decode(info))
    }

    @Test func pageModelDecodesAndBadOnesAreRefused() throws {
        let model = try Self.model(Self.info())
        #expect(model.sections.first?.rows.first?.tone == .running)
        #expect(model.sections.first?.rows.first?.buttons?.first?.action == "subagents.stop:a1")
        #expect(AgentPaneSessionInfoModel.decode(Self.info(width: .infinity)) == nil)
        #expect(AgentPaneSessionInfoModel.decode(Self.info(width: 9000)) == nil)
        #expect(AgentPaneSessionInfoModel.decode(["open": true]) == nil)
    }

    /// A short pane's popover lies over the transcript and sends no `foot`: it still gets the glass,
    /// so the chat and the panel's sections never show through each other (the faint copy of Session
    /// Info over the transcript). Over the gutter it stands on nothing, as before.
    @Test func aPanelOverTheChatGetsItsGlassEvenWithoutAFoot() throws {
        var popover = Self.info()
        popover["overChat"] = true
        #expect(AgentPaneSessionInfoPanel.liesOverChat(try Self.model(popover)))
        var aboveComposer = Self.info()
        aboveComposer["foot"] = 120
        #expect(AgentPaneSessionInfoPanel.liesOverChat(try Self.model(aboveComposer)))
        #expect(!AgentPaneSessionInfoPanel.liesOverChat(try Self.model(Self.info())))
        #expect(!AgentPaneSessionInfoPanel.liesOverChat(nil))
    }

    @Test func fractionalRowIndentAndRevealRevisionAreAcceptedAndRounded() throws {
        var raw = Self.info()
        raw["reveal"] = ["section": "subagents", "at": 3.6]
        let sectionList = try #require(raw["sections"] as? [[String: Any]])
        var section = sectionList[0]
        var rows = try #require(section["rows"] as? [[String: Any]])
        rows[0]["indent"] = 1.6
        section["rows"] = rows
        raw["sections"] = [section]
        let model = try Self.model(raw)
        #expect(model.reveal?.at == 3.6)
        guard case .line(let row) = model.items.last else {
            Issue.record("expected a Session Info row")
            return
        }
        #expect(row.indent == 2)
    }

    @Test func requestDecodesTheModelOrItsWithdrawal() throws {
        let request = AgentPaneRequest(body: ["id": "1", "method": "pane.sessionInfo", "params": ["info": Self.info()]])
        #expect(request == .sessionInfo(try Self.model(Self.info())))
        #expect(AgentPaneRequest(body: ["id": "2", "method": "pane.sessionInfo", "params": ["info": NSNull()]]) == .sessionInfo(nil))
        #expect(AgentPaneRequest(body: ["id": "3", "method": "pane.sessionInfo", "params": ["info": ["open": 1]]])
            == .unsupported("pane.sessionInfo"))
    }

    @Test func richRowsDecodeWithoutAnArbitraryListLimit() throws {
        var raw = Self.info()
        raw["sections"] = [[
            "id": "outputs", "group": "made", "title": "Outputs", "open": true, "foldable": true,
            "reorderable": true, "reorderLabel": "Reorder Outputs",
            "segments": [["share": 0.3, "color": "context0"]],
            "rows": (0..<2001).map { index in
                ["id": "row-\(index)", "title": "Report", "harness": "claude", "toggle": true,
                 "symbolColor": "purple", "menuLabel": "More actions",
                 "menu": [["label": "Copy", "action": "copy"]],
                 "hover": ["title": "Report", "detail": "More details"]] as [String: Any]
            },
        ]]
        let decoded = try Self.model(raw)
        #expect(decoded.sections[0].rows.count == 2001)
        #expect(decoded.sections[0].rows[0].toggle == true)
        #expect(decoded.sections[0].rows[0].menu?.first?.action == "copy")
        #expect(decoded.sections[0].segments?.first?.color == "context0")
        #expect(!decoded.items.contains { if case .title = $0 { true } else { false } })
    }

    @Test func activityRowsKeepWorkingWaveAndProgressFields() throws {
        var raw = Self.info()
        raw["sections"] = [[
            "id": "subagents", "group": "running", "title": "Subagents", "open": true, "foldable": true,
            "rows": [[
                "id": "agent-1", "title": "Retrying agent", "working": true,
                "wave": ["index": 2, "periodMs": 1_200, "stepMs": 120],
                "progress": "2 queued / 1 failed", "tone": "running",
            ]],
        ]]
        let decoded = try Self.model(raw)
        let row = try #require(decoded.sections[0].rows.first)
        #expect(row.working == true)
        #expect(row.wave == .init(index: 2, periodMs: 1_200, stepMs: 120))
        #expect(row.progress == "2 queued / 1 failed")
        guard case .line(let line) = decoded.items.last else {
            Issue.record("expected an activity row")
            return
        }
        #expect(line.working)
        #expect(line.wave == row.wave)
        #expect(line.progress == row.progress)
        #expect(!line.spins)
    }

    @Test func copyRequestsKeepClipboardTextOutOfDescriptions() {
        let request = AgentPaneRequest(body: ["id": "copy", "method": "pane.copyText", "params": ["text": "private reference"]])
        #expect(request == .copyText("private reference"))
        #expect(String(describing: request) == "copyText")
    }

    @Test func copyRequestsRequireARecentPersonGesture() async throws {
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), sessionId: "session-a"), source: .bundled(file)))
        defer { view.close() }
        let refused = await view.model.respond(to: .copyText("private reference"))
        #expect((refused["error"] as? [String: Any])?["code"] as? String == "transport.gesture_required")
        view.model.transport.gestures.record()
        let accepted = await view.model.respond(to: .copyText("private reference"))
        #expect(accepted["ok"] as? Bool == true)
    }

    /// The button's on state follows the panel: open makes the panel, closed removes it.
    @Test func panelFollowsTheOpenState() async throws {
        Self.enableNative()
        defer { TunableStore.shared.set(AgentPaneTunables.nativeSessionInfo.key, nil) }
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), sessionId: "session-a"), source: .bundled(file)))
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        view.layoutSubtreeIfNeeded()
        #expect(view.model.sessionInfo.panel == nil)

        _ = await view.model.respond(to: .sessionInfo(try Self.model(Self.info(open: true))))
        let panel = try #require(view.model.sessionInfo.panel)
        #expect(panel.superview === view)
        #expect(view.model.sessionInfo.isOpen)

        _ = await view.model.respond(to: .sessionInfo(try Self.model(Self.info(open: false))))
        #expect(view.model.sessionInfo.panel == nil)
        #expect(panel.superview == nil)
        #expect(!view.model.sessionInfo.isOpen)

        _ = await view.model.respond(to: .sessionInfo(try Self.model(Self.info(open: true))))
        _ = await view.model.respond(to: .sessionInfo(nil))
        #expect(view.model.sessionInfo.panel == nil)
        view.close()
    }

    /// Debug Settings' toggle off takes the App's panel down at once (the page is told, and draws its
    /// own), and on again brings it back, with no reload.
    @Test(.timeLimit(.minutes(1))) func killSwitchTakesThePanelDownAtOnce() async throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register([AgentPaneTunables.nativeSessionInfo.descriptor])
        TunableStore.shared.set(AgentPaneTunables.nativeSessionInfo.key, .bool(true))
        defer { TunableStore.shared.set(AgentPaneTunables.nativeSessionInfo.key, nil) }
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), sessionId: "session-a"), source: .bundled(file)))
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        _ = await view.model.respond(to: .sessionInfo(try Self.model(Self.info(open: true))))
        #expect(view.model.sessionInfo.panel != nil)

        TunableStore.shared.set(AgentPaneTunables.nativeSessionInfo.key, .bool(false))
        while view.model.sessionInfo.panel != nil, !Task.isCancelled { await Task.yield() }
        #expect(view.model.sessionInfo.panel == nil)
        #expect(!view.drawsSessionInfo)

        TunableStore.shared.set(AgentPaneTunables.nativeSessionInfo.key, .bool(true))
        while view.model.sessionInfo.panel == nil, !Task.isCancelled { await Task.yield() }
        #expect(view.model.sessionInfo.panel != nil)
        view.close()
    }

    /// Full length: from under the header to the pane's foot less the float margin, at the pane's
    /// right edge; over the chat's column it stops above the composer (`foot`).
    @Test func panelRunsTheFullHeightOfThePage() throws {
        let page = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let full = AgentPaneView.sessionInfoFrame(page: page, info: try Self.model(Self.info(top: 28)), width: 320, zoom: 1, flipped: true)
        #expect(full == CGRect(x: 1000 - 8 - 320, y: 28, width: 320, height: 800 - 28 - 8))
        let zoomed = AgentPaneView.sessionInfoFrame(page: page, info: try Self.model(Self.info(top: 28)), width: 320, zoom: 1.25, flipped: true)
        #expect(zoomed == CGRect(x: 1000 - 10 - 400, y: 35, width: 400, height: 800 - 35 - 10))
        let beside = AgentPaneView.sessionInfoFrame(page: page, info: try Self.model(Self.info(side: 300)), width: 320, zoom: 1, flipped: true)
        #expect(beside == CGRect(x: 1000 - 300 - 8 - 320, y: 28, width: 320, height: 800 - 28 - 8))
        let overChat = AgentPaneView.sessionInfoFrame(page: page, info: try Self.model(Self.info(top: 28, foot: 120)), width: 320, zoom: 1, flipped: true)
        #expect(overChat == CGRect(x: 1000 - 8 - 320, y: 28, width: 320, height: 800 - 28 - 120))
    }

    /// It ends after its last section: as tall as its content, up to the room above the foot, top
    /// anchored under the header in either coordinate system (Leo, 2026-11-02: "IT IS TAKING THIS
    /// STUPID FUCKING SPACE FOR NO REASON").
    @Test func panelHugsItsContentWithNoEmptySpaceUnderIt() throws {
        let page = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let info = try Self.model(Self.info(top: 28))
        var asked: [CGFloat] = []
        let short = AgentPaneView.sessionInfoFrame(page: page, info: info, width: 320, zoom: 1, flipped: true,
                                                   content: { asked.append($0); return 140.4 })
        #expect(asked == [320])
        #expect(short == CGRect(x: 1000 - 8 - 320, y: 28, width: 320, height: 141))
        let unflipped = AgentPaneView.sessionInfoFrame(page: page, info: info, width: 320, zoom: 1, flipped: false,
                                                       content: { _ in 141 })
        #expect(unflipped == CGRect(x: 1000 - 8 - 320, y: 800 - 28 - 141, width: 320, height: 141))
        let tall = AgentPaneView.sessionInfoFrame(page: page, info: info, width: 320, zoom: 1, flipped: true,
                                                  content: { _ in 5000 })
        #expect(tall == CGRect(x: 1000 - 8 - 320, y: 28, width: 320, height: 800 - 28 - 8))

        // The panel measures its real list: a row more makes it taller, and nothing is left under it.
        let store = AgentPaneSessionInfoStore()
        let panel = AgentPaneSessionInfoPanel(store: store)
        var relayouts = 0
        store.relayout = { relayouts += 1 }
        store.update(try Self.model(Self.info()))
        let one = panel.fittingHeight(forWidth: 320)
        #expect(one > 0 && one < 200)
        var two = Self.info()
        var section = (two["sections"] as? [[String: Any]])?.first ?? [:]
        section["rows"] = ((section["rows"] as? [[String: Any]]) ?? []) + [["id": "a2", "title": "second", "tone": "running"]]
        two["sections"] = [section]
        panel.frame = CGRect(x: 0, y: 0, width: 320, height: one)
        panel.layoutSubtreeIfNeeded()
        relayouts = 0
        store.update(try Self.model(two))
        #expect(panel.fittingHeight(forWidth: 320) > one)
        #expect(relayouts > 0)
    }

    /// Leo (2026-11-03): "i mean there's literally no scrollbar in claude code it's just scrollable". The
    /// list's scroll view draws no scroller and keeps no width for one, and still scrolls: a list taller
    /// than the panel moves when the clip view is scrolled.
    @Test func panelScrollsWithNoScrollbar() throws {
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let store = AgentPaneSessionInfoStore()
        let panel = AgentPaneSessionInfoPanel(store: store)
        panel.frame = CGRect(x: 0, y: 0, width: 320, height: 60)
        var info = Self.info()
        var section = (info["sections"] as? [[String: Any]])?.first ?? [:]
        section["rows"] = (0..<40).map { ["id": "r\($0)", "title": "row \($0)", "tone": "running"] }
        info["sections"] = [section]
        store.update(try Self.model(info))
        panel.layoutSubtreeIfNeeded()
        let scroll = try #require(all(panel).compactMap { $0 as? NSScrollView }.first)
        #expect(!scroll.hasVerticalScroller)
        #expect(!scroll.hasHorizontalScroller)
        #expect(scroll.contentSize.width == scroll.frame.width)
        let document = try #require(scroll.documentView)
        #expect(document.frame.height > scroll.contentSize.height)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 40))
        #expect(scroll.contentView.bounds.minY == 40)
    }

    /// Over the gutter the content stands on the pane (no card). Over the chat's column (`foot`) the
    /// transcript runs under it, so there it lies on the overlay glass, which follows Reduce
    /// Transparency (the solid surface), and loses it again back over the gutter.
    @Test func panelHasGlassUnderItOnlyOverTheChat() throws {
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let store = AgentPaneSessionInfoStore()
        let panel = AgentPaneSessionInfoPanel(store: store)
        panel.frame = CGRect(x: 0, y: 0, width: 320, height: 300)
        store.update(try Self.model(Self.info()))
        panel.layoutSubtreeIfNeeded()
        #expect(panel.backing == nil)
        #expect(!all(panel).contains { $0 is OverlaySurfaceView || $0 is NSVisualEffectView })

        store.update(try Self.model(Self.info(foot: 120)))
        panel.layoutSubtreeIfNeeded()
        let backing = try #require(panel.backing)
        #expect(backing.frame == panel.bounds)
        let content = try #require(panel.subviews.firstIndex { $0 is AgentPaneSessionInfoContent })
        #expect(panel.subviews.firstIndex { $0 === backing }! < content)
        backing.materialOverride = .opaque
        #expect(backing.material == .opaque)

        store.update(try Self.model(Self.info()))
        #expect(panel.backing == nil)
        #expect(!all(panel).contains { $0 is OverlaySurfaceView })
    }

    /// Leo (2026-11-03): "maybe it's ok...? to HAVE NO BACKGROUND FOR THE SESSION INFO / but i think having a
    /// border for it might be better". The panel paints no fill of its own and draws a hairline edge in the
    /// separator color on its rounded corners, over the gutter and over the chat's glass alike.
    @Test func panelHasAHairlineEdgeAndNoFill() throws {
        let store = AgentPaneSessionInfoStore()
        let panel = AgentPaneSessionInfoPanel(store: store)
        panel.frame = CGRect(x: 0, y: 0, width: 320, height: 300)
        var colors = AgentPaneSessionInfoColors()
        colors.separator = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 0.5)
        store.colors = colors
        for foot in [nil, 120.0] as [Double?] {
            store.update(try Self.model(Self.info(foot: foot)))
            panel.layoutSubtreeIfNeeded()
            let layer = try #require(panel.layer)
            #expect(layer.backgroundColor == nil, "the panel paints a fill of its own")
            #expect(layer.borderWidth > 0 && layer.borderWidth <= 1, "no hairline edge (width \(layer.borderWidth))")
            #expect(layer.cornerRadius > 0)
            let edge = try #require(layer.borderColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) })
            #expect(abs(edge.blueComponent - 0.6) < 0.01 && abs(edge.alphaComponent - 0.5) < 0.01)
        }
    }

    /// cmuxterm-hq#6137: pushed in a narrow pane, the page narrows the panel below 260px and keeps that
    /// room beside the chat (SessionInfo.tsx pushedWidth, `.acpmux-session-info-room`). The App draws
    /// the panel in exactly that room: its left edge is the chat's right edge, so nothing floats over it.
    @Test func pushedPanelFillsThePagesRoomExactly() throws {
        for (pane, pushed) in [(370.0, 200.0), (528.0, 200.0), (740.0, 292.0)] {
            let page = CGRect(x: 0, y: 0, width: pane, height: 900)
            let frame = AgentPaneView.sessionInfoFrame(page: page, info: try Self.model(Self.info(width: pushed)),
                                                       width: pushed, zoom: 1, flipped: true)
            let chatRight = pane - pushed - 8
            // Within half a point: the frame is pixel-aligned (`.integral`), so exact equality on
            // CGFloat is brittle across hosts.
            #expect(abs(Double(frame.minX) - chatRight) < 0.5, "minX \(frame.minX) vs \(chatRight)")
            #expect(abs(Double(frame.width) - pushed) < 0.5, "width \(frame.width) vs \(pushed)")
            #expect(abs(Double(frame.maxX) - (pane - 8)) < 0.5, "maxX \(frame.maxX) vs \(pane - 8)")
        }
    }

    /// After a drag ends the page's answer is drawn even where it differs from the drag's width (the
    /// pushed panel's narrow floor), so the native frame never stays wider than the page's room.
    @Test func pageWidthReplacesTheDragOnceTheDragEnds() throws {
        let store = AgentPaneSessionInfoStore()
        store.update(try Self.model(Self.info(width: 200)))
        store.drag(by: -100, ended: true)
        #expect(store.width == 300)
        store.update(try Self.model(Self.info(width: 200)))
        #expect(store.width == 200)
    }

    @Test func rowAnchorsUsePageCoordinatesAndTheActiveZoom() {
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let topLeft = CGRect(x: 600, y: 120, width: 300, height: 30)
        let bottomLeft = CGRect(x: 600, y: 750, width: 300, height: 30)
        #expect(AgentPaneView.sessionInfoPageRect(topLeft, bounds: bounds, flipped: true, zoom: 1) == topLeft)
        #expect(AgentPaneView.sessionInfoPageRect(bottomLeft, bounds: bounds, flipped: false, zoom: 1) == topLeft)
        let zoomed = CGRect(x: 400, y: 80, width: 200, height: 20)
        #expect(AgentPaneView.sessionInfoPageRect(topLeft, bounds: bounds, flipped: true, zoom: 1.5) == zoomed)
        #expect(AgentPaneView.sessionInfoPageRect(bottomLeft, bounds: bounds, flipped: false, zoom: 1.5) == zoomed)
    }

    @Test(.timeLimit(.minutes(1))) func sharedHostReplayKeepsFollowingTheDebugSwitch() async throws {
        Self.enableNative()
        defer { TunableStore.shared.set(AgentPaneTunables.nativeSessionInfo.key, nil) }
        TunableStore.shared.set(AgentPaneTunables.nativeSessionInfo.key, .bool(false))
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), sessionId: "session-a"), source: .bundled(file), pageHost: true))
        defer { view.close() }
        let (events, sink) = AsyncStream.makeStream(of: JSONValue.self)
        let provider = try #require(view.pageEvents)
        let subscription = try await provider.subscribe(
            AgentPageProvider.hostEvents, filter: .null, context: PageCallContext(page: PageDescriptor.agent.id)
        ) { sink.yield($0) }
        defer { subscription.cancel() }
        #expect(view.model.sessionInfo.announced == false)
        TunableStore.shared.set(AgentPaneTunables.nativeSessionInfo.key, .bool(true))
        for await event in events where event == AgentPageEvent.sessionInfoHost(true).data { break }
        #expect(view.model.sessionInfo.announced == true)
        TunableStore.shared.set(AgentPaneTunables.nativeSessionInfo.key, .bool(false))
        for await event in events where event == AgentPageEvent.sessionInfoHost(false).data { break }
        #expect(view.model.sessionInfo.announced == false)
    }

    @Test func nativeKeyboardActionsKeepThePersonInputCheck() throws {
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), sessionId: "session-a"), source: .bundled(file)))
        defer { view.close() }
        let key = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true))
        key.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        view.forwardSessionInfoAction("environment.remoteControl", event: try #require(NSEvent(cgEvent: key)))
        #expect(view.model.transport.gestures.consume())
        key.setIntegerValueField(.eventSourceUnixProcessID, value: 999999)
        view.forwardSessionInfoAction("environment.remoteControl", event: try #require(NSEvent(cgEvent: key)))
        #expect(!view.model.transport.gestures.consume())
        view.forwardSessionInfoAction("environment.remoteControl", event: nil)
        #expect(!view.model.transport.gestures.consume())
    }

    @Test(arguments: [false, true]) func rendererTerminationRetiresThePanelAndItsHole(reloading: Bool) async throws {
        Self.enableNative()
        defer { TunableStore.shared.set(AgentPaneTunables.nativeSessionInfo.key, nil) }
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), sessionId: "session-a"), source: .bundled(file), pageHost: true))
        defer { view.close() }
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        view.layoutSubtreeIfNeeded()
        _ = await view.model.respond(to: .sessionInfo(try Self.model(Self.info())))
        #expect(view.model.sessionInfo.panel != nil)
        view.pageCrashed(reloading: reloading)
        #expect(view.model.sessionInfo.panel == nil)
        #expect(view.model.sessionInfo.info == nil)
        #expect(view.page?.nativeRects == view.model.tabRow.holes)
    }

    /// A click in the panel goes to the page as `sessionInfoAction`, the row's own id.
    @Test(.timeLimit(.minutes(1))) func panelClicksReachThePage() async throws {
        Self.enableNative()
        defer { TunableStore.shared.set(AgentPaneTunables.nativeSessionInfo.key, nil) }
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), sessionId: "session-a"), source: .bundled(file), pageHost: true))
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        let (events, sink) = AsyncStream.makeStream(of: JSONValue.self)
        let provider = try #require(view.pageEvents)
        let subscription = try await provider.subscribe(
            AgentPageProvider.hostEvents, filter: .null, context: PageCallContext(page: PageDescriptor.agent.id)
        ) { sink.yield($0) }
        defer { subscription.cancel() }

        _ = await view.model.respond(to: .sessionInfo(try Self.model(Self.info())))
        let panel = try #require(view.model.sessionInfo.panel)
        panel.store.act("subagents.stop:a1")
        let expected = AgentPageEvent.sessionInfoAction("subagents.stop:a1").data
        for await event in events where event["kind"] == .string("sessionInfoAction") {
            #expect(event == expected)
            break
        }
        view.close()
    }

    /// On the old host (no page host: a dev-server page, `agent.pageHost` off) the panel's actions reach
    /// the page as scripts. They must run: `?.action?(…)` was a syntax error, so the panel's own close
    /// (Esc) never told the page, which kept Session Info open and its header toggle lit after a close.
    @Test func oldHostActionScriptsRunAndReachThePage() throws {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var sent = []; var hosted = [];
        var window = { cmuxAcpmuxSessionInfo: { action: function (v) { sent.push(v); }, host: function (v) { hosted.push(v); } } };
        """)
        for script in [AgentPaneSessionInfo.actionScript("close"),
                       AgentPaneSessionInfo.actionScript("environment.menu", rect: CGRect(x: 1, y: 2, width: 3, height: 4)),
                       AgentPaneSessionInfo.hostScript(true)] {
            context.exception = nil
            context.evaluateScript(script)
            #expect(context.exception == nil, "\(script)")
        }
        #expect(context.evaluateScript("sent.length")?.toInt32() == 2)
        #expect(context.evaluateScript("sent[0]")?.toString() == "close")
        #expect(context.evaluateScript("sent[1].id + ':' + sent[1].rect.bottom")?.toString() == "environment.menu:6")
        #expect(context.evaluateScript("hosted[0]")?.toBool() == true)
        // A page with no Session Info bridge yet ignores them.
        context.evaluateScript("window = {};")
        context.exception = nil
        context.evaluateScript(AgentPaneSessionInfo.actionScript("close"))
        #expect(context.exception == nil)
    }

    /// A click anywhere in the panel gives it the keyboard, so Esc closes it wherever the page's focus
    /// was (the composer, say), as a click in the page's panel focused it; no ring is drawn for it.
    @Test func aClickInThePanelTakesTheKeyboardSoEscClosesIt() throws {
        let store = AgentPaneSessionInfoStore()
        var sent: [String] = []
        store.send = { sent.append($0) }
        let panel = AgentPaneSessionInfoPanel(store: store)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        let host = try #require(window.contentView)
        let page = NSTextView(frame: CGRect(x: 0, y: 0, width: 80, height: 600))
        host.addSubview(page)
        panel.frame = CGRect(x: 80, y: 0, width: 320, height: 600)
        host.addSubview(panel)
        store.update(try Self.model(Self.info()))
        panel.layoutSubtreeIfNeeded()
        #expect(window.makeFirstResponder(page))
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let line = try #require(all(panel).compactMap { $0 as? SessionInfoLineView }.first)
        let point = NSPoint(x: line.bounds.midX, y: line.bounds.midY)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                   clickCount: 1, pressure: 1))
        line.mouseDown(with: down)
        #expect(window.firstResponder === panel)
        #expect(panel.focusRingMaskBounds == .zero)
        // A second click keeps it (no churn), and a click on empty glass reaches the panel too.
        line.mouseDown(with: down)
        #expect(window.firstResponder === panel)
        #expect(window.makeFirstResponder(page))
        panel.mouseDown(with: down)
        #expect(window.firstResponder === panel)
        // Esc from there: the panel's own close goes to the page.
        #expect(window.firstResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil) == true)
        #expect(sent.last == "close")
    }

    /// The panel is AppKit (no SwiftUI host): its lines follow the model, and a line's or a button's
    /// click sends that action; a folded section shows its title row alone.
    @Test func panelIsAppKitAndItsLinesRunTheirActions() throws {
        let store = AgentPaneSessionInfoStore()
        var sent: [String] = []
        store.send = { sent.append($0) }
        let panel = AgentPaneSessionInfoPanel(store: store)
        panel.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        store.update(try Self.model(Self.info()))
        panel.layoutSubtreeIfNeeded()
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        #expect(!all(panel).contains { String(describing: type(of: $0)).contains("NSHostingView") })
        // No background card: the content sits on the pane's glass, with no surface of its own behind it.
        #expect(!all(panel).contains { $0 is OverlaySurfaceView || $0 is NSVisualEffectView })
        let content = try #require(all(panel).compactMap { $0 as? AgentPaneSessionInfoContent }.first)
        #expect(content.lines.map(\.line.title) == ["Subagents", "rail-fix"])
        #expect(content.lines[0].press())
        #expect(content.lines[1].press())
        #expect(content.lines[1].buttons.first?.press() == true)
        #expect(sent == ["fold:subagents:0", "subagents.open:a1", "subagents.stop:a1"])

        var folded = Self.info()
        var section = (folded["sections"] as? [[String: Any]])?.first ?? [:]
        section["open"] = false
        folded["sections"] = [section]
        store.update(try Self.model(folded))
        #expect(content.lines.map(\.line.title) == ["Subagents"])
        #expect(content.lines[0].line.action == "fold:subagents:1")
    }

    /// A long section title on a narrow panel leaves the fold chevron clear of the meta beside it,
    /// and Space on a focused button presses it as on a push button.
    @Test func narrowHeaderKeepsItsChevronClearAndSpacePressesAButton() throws {
        var sent: [String] = []
        let ink = SessionInfoInk(colors: AgentPaneSessionInfoColors(), act: { id, _ in sent.append(id) }, rect: { _ in nil })
        let header = SessionInfoLineView(line: SessionInfoLine(
            kind: .header, title: String(repeating: "Background tasks ", count: 6), trailing: "12 running", unfolded: true,
            action: "fold:tasks:0"), ink: ink)
        header.frame = CGRect(x: 0, y: 0, width: 180, height: 26)
        header.layoutSubtreeIfNeeded()
        let frames = header.subviews.map(\.frame)
        let chevron = try #require(header.subviews.first { $0 is NSImageView }).frame
        let meta = try #require(frames.max { $0.minX < $1.minX })
        #expect(chevron.maxX <= meta.minX)

        let stop = SessionInfoButtonView(button: .init(label: "Stop", symbol: nil, action: "tasks.stop:1", disabled: nil), ink: ink)
        let space = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                  context: nil, characters: " ", charactersIgnoringModifiers: " ",
                                                  isARepeat: false, keyCode: 49))
        stop.keyDown(with: space)
        #expect(sent == ["tasks.stop:1"])
        let capsReturn = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.capsLock], timestamp: 0,
                                                       windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                                       isARepeat: false, keyCode: 36))
        stop.keyDown(with: capsReturn)
        #expect(sent == ["tasks.stop:1", "tasks.stop:1"])
        #expect(stop.acceptsFirstResponder)
    }

    /// A drag of the panel's left edge widens it at once and hands the page the width when it ends.
    @Test func edgeDragWidensThePanelAndTellsThePage() throws {
        let store = AgentPaneSessionInfoStore()
        store.update(try Self.model(Self.info(width: 320)))
        var sent: [String] = []
        store.send = { sent.append($0) }
        store.drag(by: -40, ended: false)
        #expect(store.width == 360)
        #expect(sent.isEmpty)
        store.drag(by: -1000, ended: true)
        #expect(store.width == 560)
        #expect(sent == ["width:560"])
        store.update(try Self.model(Self.info(width: 560)))
        #expect(store.dragWidth == nil)
    }

    @Test func aHeaderClickFoldsInsteadOfReordering() throws {
        var sent: [String] = []
        let ink = SessionInfoInk(colors: AgentPaneSessionInfoColors(), act: { id, _ in sent.append(id) }, rect: { _ in nil })
        let header = SessionInfoLineView(line: SessionInfoLine(
            id: "context", kind: .header, title: "Context", unfolded: true, reorderable: true,
            action: "fold:context:0"), ink: ink)
        header.frame = CGRect(x: 0, y: 0, width: 320, height: 26)
        header.layoutSubtreeIfNeeded()
        let title = try #require(header.subviews.compactMap { $0 as? ChromeLabel }.first { $0.stringValue == "Context" })
        let point = NSPoint(x: title.frame.midX, y: title.frame.midY)
        let target = try #require(header.hitTest(point))
        func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                           timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                           clickCount: 1, pressure: 1))
        }
        target.mouseDown(with: try mouse(.leftMouseDown))
        target.mouseUp(with: try mouse(.leftMouseUp))
        #expect(sent == ["fold:context:0"])
    }

    /// Section headers follow the web panel's SessionInfoSection: a medium-weight title (never the bold
    /// chrome header) on the rows' title column, a chevron after the title that shows on hover, and the
    /// six-dot grip at the header's right edge that shows only on hover. At rest neither glyph draws, no
    /// `line.3.horizontal` grip sits over the icons, and hovering moves no title (Leo, 2026-11-02: "WE
    /// FUCKING HAD THESE" and, on the always-on grips, "THESE ARE JUST SO INSANELY STUPID LOOKING").
    @Test func sectionHeadersShowTheirChevronAndRightEdgeGripOnlyOnHover() throws {
        let ink = SessionInfoInk(colors: AgentPaneSessionInfoColors(), act: { _, _ in }, rect: { _ in nil })
        func view(_ line: SessionInfoLine) -> SessionInfoLineView {
            let view = SessionInfoLineView(line: line, ink: ink)
            view.frame = CGRect(x: 0, y: 0, width: 320, height: 26)
            view.layoutSubtreeIfNeeded()
            return view
        }
        func title(_ view: SessionInfoLineView) throws -> NSRect {
            try #require(view.subviews.compactMap { $0 as? ChromeLabel }.first { $0.stringValue == view.line.title }).frame
        }
        func grip(_ view: SessionInfoLineView) -> SessionInfoGripView? {
            view.subviews.compactMap { $0 as? SessionInfoGripView }.first
        }
        func images(_ view: SessionInfoLineView) -> [NSImageView] { view.subviews.compactMap { $0 as? NSImageView } }

        let context = view(SessionInfoLine(id: "context", kind: .header, symbol: "gauge", title: "Context", trailing: "42%",
                                           unfolded: true, reorderable: true, action: "fold:context:0"))
        let changes = view(SessionInfoLine(id: "changes", kind: .header, title: "Changes", trailing: "3", unfolded: false,
                                           reorderable: true, action: "fold:changes:1"))
        let plain = view(SessionInfoLine(id: "plain", kind: .header, title: "Usage", reorderable: true))
        let machine = view(SessionInfoLine(id: "environment", kind: .row, symbol: "desktopcomputer", title: "cosmic-gray", reorderable: true))
        let row = view(SessionInfoLine(id: "row:context:mcp", kind: .row, symbol: "gauge", title: "MCP tools"))

        // Titles are the web's weight (500, medium), not bold, at the rows' size.
        for header in [context, changes, plain] {
            let font = header.line.font
            let weight = (font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat
            #expect(weight.map { $0 < NSFont.Weight.semibold.rawValue } == true)
            #expect(!font.fontDescriptor.symbolicTraits.contains(.bold))
            #expect(font.pointSize == row.line.font.pointSize)
        }
        // A header with an icon puts its title on the rows' title column; the grip adds no room.
        #expect(try title(context).minX == title(row).minX)
        #expect(try title(machine).minX == title(row).minX)

        // At rest: no grip, no chevron, and nothing but the line's own icon as an image.
        for line in [context, changes, plain, machine] {
            #expect(!line.showsGrip)
            #expect(grip(line)?.isHidden == true)
            #expect(!line.showsChevron)
            let titleX = try title(line).minX
            #expect(images(line).allSatisfy { $0.isHidden || $0.frame.maxX <= titleX })
        }
        #expect(images(changes).filter { !$0.isHidden }.isEmpty)
        // Foldable headers carry a chevron; a plain one does not.
        #expect(images(context).count == 2)
        #expect(images(changes).count == 1)
        #expect(images(plain).isEmpty)

        let enter = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        for line in [context, changes, plain, machine] {
            let before = try title(line)
            line.mouseEntered(with: enter)
            line.layoutSubtreeIfNeeded()
            #expect(line.showsGrip)
            #expect(try title(line) == before)
            // The grip sits in the line's right inset, past every trailing value, at the right edge.
            let handle = try #require(grip(line))
            #expect(!handle.isHidden)
            #expect(handle.frame.size == SessionInfoGripView.size)
            #expect(handle.frame.maxX <= line.bounds.maxX)
            #expect(line.bounds.maxX - handle.frame.maxX <= 2)
            for other in line.subviews where other !== handle && !other.isHidden {
                #expect(other.frame.maxX <= handle.frame.minX)
            }
            if line.line.unfolded != nil {
                // The chevron shows one grid gap after the title, before the meta.
                #expect(line.showsChevron)
                let chevron = try #require(images(line).first { !$0.isHidden && $0.frame.minX > before.maxX })
                #expect(chevron.frame.minX == before.maxX + LayoutGrid.gap)
                #expect(chevron.frame.width == LayoutGrid.iconBox)
            }
            line.mouseExited(with: enter)
            #expect(!line.showsGrip)
            #expect(grip(line)?.isHidden == true)
            #expect(!line.showsChevron)
        }
    }

    /// Dragging a header by its grip moves its section above the one it is dropped on; a click on the
    /// grip alone neither folds nor moves.
    @Test func dragByTheGripReordersSections() throws {
        let store = AgentPaneSessionInfoStore()
        var sent: [String] = []
        store.send = { sent.append($0) }
        let panel = AgentPaneSessionInfoPanel(store: store)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
        defer { window.close() }
        window.isReleasedWhenClosed = false
        window.contentView = panel
        panel.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        let sections: [[String: Any]] = ["Context", "Changes"].map { title in
            ["id": title.lowercased(), "group": "where", "title": title, "meta": "3", "open": false, "foldable": true,
             "reorderable": true, "reorderLabel": "Move \(title)", "rows": [[String: Any]]()]
        }
        let info: [String: Any] = ["open": true, "width": 320, "top": 28, "side": 0, "label": "Session Info", "sections": sections]
        store.update(try Self.model(info))
        panel.layoutSubtreeIfNeeded()
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let content = try #require(all(panel).compactMap { $0 as? AgentPaneSessionInfoContent }.first)
        #expect(content.lines.map(\.line.title) == ["Context", "Changes"])
        let context = content.lines[0], changes = content.lines[1]
        let hit = try #require(changes.gripHitRect)
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint, in view: NSView) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                                           timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                           clickCount: 1, pressure: 1))
        }
        let start = NSPoint(x: hit.midX, y: hit.midY)

        // A click on the grip does nothing.
        changes.mouseDown(with: try mouse(.leftMouseDown, start, in: changes))
        changes.mouseUp(with: try mouse(.leftMouseUp, start, in: changes))
        #expect(sent.isEmpty)

        // A drag from the grip to the top of Context moves Changes before it.
        let drop = changes.convert(NSPoint(x: context.bounds.midX, y: context.bounds.minY + 2), from: context)
        changes.mouseDown(with: try mouse(.leftMouseDown, start, in: changes))
        changes.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: start.x, y: start.y + (drop.y - start.y) / 2), in: changes))
        #expect(changes.isDragging)
        #expect(changes.showsGrip)
        changes.mouseUp(with: try mouse(.leftMouseUp, drop, in: changes))
        #expect(sent == ["move:changes:context"])
        #expect(!changes.isDragging)
    }

    /// No section header ever draws a fill behind it, hovered or not, and a lit row that leaves the
    /// panel (a refresh re-adds every line) comes back unlit instead of keeping its fill at rest (Leo,
    /// 2026-11-02: "we still HAVE AN ASININE FUCKIGN BACKGROUND").
    @Test func headersNeverDrawAFillAndARowsHoverEndsWithTheRow() throws {
        let ink = SessionInfoInk(colors: AgentPaneSessionInfoColors(), act: { _, _ in }, rect: { _ in nil })
        let enter = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                        windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        let host = try #require(window.contentView)
        for line in [
            SessionInfoLine(id: "changes", kind: .header, title: "Changes", unfolded: true, reorderable: true, action: "fold:changes:0"),
            SessionInfoLine(id: "sources", kind: .header, title: "Sources", unfolded: false, action: "fold:sources:1"),
        ] {
            let header = SessionInfoLineView(line: line, ink: ink)
            host.addSubview(header)
            header.mouseEntered(with: enter)
            #expect(header.layer?.backgroundColor == nil, "\(line.title)'s header drew a fill")
        }
        let row = SessionInfoLineView(line: SessionInfoLine(id: "row:changes:a", kind: .row, title: "a.swift", action: "changes.open:a"), ink: ink)
        host.addSubview(row)
        row.mouseEntered(with: enter)
        #expect(row.layer?.backgroundColor != nil)
        row.removeFromSuperview()
        host.addSubview(row)
        #expect(row.layer?.backgroundColor == nil, "a re-added row kept its hover fill with the pointer gone")
    }

    @Test func liveLabelsKeepUnchangedHeaderViews() throws {
        let store = AgentPaneSessionInfoStore()
        let panel = AgentPaneSessionInfoPanel(store: store)
        store.update(try Self.model(Self.info()))
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let content = try #require(all(panel).compactMap { $0 as? AgentPaneSessionInfoContent }.first)
        let header = try #require(content.lines.first)
        let row = try #require(content.lines.last)
        let stop = try #require(row.buttons.first)
        store.update(try Self.model(Self.info()))
        #expect(content.lines.last === row)
        #expect(content.lines.last?.buttons.first === stop)
        var next = Self.info()
        var sections = try #require(next["sections"] as? [[String: Any]])
        var rows = try #require(sections[0]["rows"] as? [[String: Any]])
        rows[0]["trailing"] = "2s"
        sections[0]["rows"] = rows
        next["sections"] = sections
        store.update(try Self.model(next))
        #expect(content.lines.first === header)
        #expect(content.lines.last === row)
        #expect(content.lines.last?.buttons.first !== stop)
        #expect(content.lines.last?.line.trailing == "2s")

        rows[0]["subtitle"] = "updated subtitle"
        rows[0]["detail"] = "updated detail"
        rows[0]["meter"] = 0.42
        rows[0]["marks"] = ["done", "failed"]
        rows[0]["toggle"] = true
        rows[0]["menu"] = [["label": "Copy", "action": "copy:new"]]
        rows[0]["action"] = "subagents.open:new"
        sections[0]["rows"] = rows
        next["sections"] = sections
        store.update(try Self.model(next))
        #expect(content.lines.last === row)
        #expect(content.lines.last?.line.subtitle == "updated subtitle")
        #expect(content.lines.last?.line.detail == "updated detail")
        #expect(content.lines.last?.line.meter == 0.42)
        #expect(content.lines.last?.line.marks?.count == 2)
        #expect(content.lines.last?.line.toggle == true)
        #expect(content.lines.last?.line.action == "subagents.open:new")
        #expect(content.lines.last?.buttons.first?.button.action == "subagents.stop:a1")
    }

    /// Leo, 2026-11-02: "layering issue the context should go over top of the session info". The page
    /// reports its open popups; the request carries them and refuses bad ones.
    @Test func overlayReportsDecodeAndBadOnesAreRefused() {
        let request = AgentPaneRequest(body: ["id": "o", "method": "pane.sessionInfo.overlays", "params": [
            "rects": [["left": 40, "top": 300, "right": 260, "bottom": 480, "radius": 12]],
        ]])
        #expect(request == .sessionInfoOverlays([
            AgentPaneSessionInfoOverlay(rect: CGRect(x: 40, y: 300, width: 220, height: 180), radius: 12),
        ]))
        #expect(String(describing: request) == "sessionInfoOverlays")
        let closed = AgentPaneRequest(body: ["id": "o", "method": "pane.sessionInfo.overlays", "params": ["rects": []]])
        #expect(closed == .sessionInfoOverlays([]))
        let inverted = AgentPaneRequest(body: ["id": "o", "method": "pane.sessionInfo.overlays", "params": [
            "rects": [["left": 260, "top": 300, "right": 40, "bottom": 480]],
        ]])
        #expect(inverted == .unsupported("pane.sessionInfo.overlays"))
        let tooMany = AgentPaneRequest(body: ["id": "o", "method": "pane.sessionInfo.overlays", "params": [
            "rects": Array(repeating: ["left": 0, "top": 0, "right": 1, "bottom": 1], count: 17),
        ]])
        #expect(tooMany == .unsupported("pane.sessionInfo.overlays"))
        #expect(AgentPageOps.methods.values.contains("pane.sessionInfo.overlays"))
    }

    /// A popup's viewport rect lands in pane coordinates in either flip and at the page's zoom.
    @Test func overlayRectsUsePageCoordinatesAndTheActiveZoom() {
        let page = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let css = CGRect(x: 600, y: 120, width: 300, height: 30)
        #expect(AgentPaneView.sessionInfoOverlayRect(css, page: page, zoom: 1, flipped: true) == css)
        #expect(AgentPaneView.sessionInfoOverlayRect(css, page: page, zoom: 1, flipped: false)
            == CGRect(x: 600, y: 750, width: 300, height: 30))
        #expect(AgentPaneView.sessionInfoOverlayRect(css, page: page, zoom: 1.5, flipped: true)
            == CGRect(x: 900, y: 180, width: 450, height: 45))
    }

    /// A reported popup over the panel cuts it out (no drawing, no clicks there, and a Chromium page
    /// uncovered around it), and the panel is whole again once the popup closes.
    @Test func aReportedPopupMakesThePanelYieldThereAndRestoresAfter() async throws {
        Self.enableNative()
        defer { TunableStore.shared.set(AgentPaneTunables.nativeSessionInfo.key, nil) }
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), sessionId: "session-a"), source: .bundled(file)))
        defer { view.close() }
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        view.layoutSubtreeIfNeeded()
        _ = await view.model.respond(to: .sessionInfo(try Self.model(Self.info(open: true))))
        let panel = try #require(view.model.sessionInfo.panel)
        panel.layoutSubtreeIfNeeded()
        #expect(panel.holes.isEmpty)
        #expect(panel.layer?.mask == nil)
        #expect(panel.uncoveredRects() == [panel.bounds])
        let inside = view.convert(CGPoint(x: panel.bounds.midX, y: panel.bounds.midY), from: panel)
        #expect(panel.hitTest(inside) != nil)

        // A card from the composer reaching 80 px into the panel's left side, over its middle.
        let pageFrame = view.page?.frame ?? view.webView.frame
        let panelInPage = AgentPaneView.sessionInfoPageRect(panel.frame, bounds: pageFrame, flipped: view.isFlipped, zoom: 1)
        let card = CGRect(x: panelInPage.minX - 120, y: panelInPage.midY - 50, width: 200, height: 100)
        _ = await view.model.respond(to: .sessionInfoOverlays([AgentPaneSessionInfoOverlay(rect: card, radius: 10)]))
        let hole = try #require(panel.holes.first)
        #expect(panel.holes.count == 1)
        #expect(abs(hole.rect.width - 200) < 1 && abs(hole.rect.height - 100) < 1)
        #expect(abs(hole.rect.maxX - 80) < 1)
        #expect(panel.layer?.mask != nil)
        let inHole = view.convert(CGPoint(x: 40, y: hole.rect.midY), from: panel)
        #expect(panel.hitTest(inHole) == nil)
        let clear = view.convert(CGPoint(x: panel.bounds.maxX - 20, y: hole.rect.midY), from: panel)
        #expect(panel.hitTest(clear) != nil)
        let pieces = panel.uncoveredRects()
        #expect(!pieces.contains { $0.intersects(hole.rect.insetBy(dx: 1, dy: 1)) })
        // The panel ends after its content (#32661), so it may be shorter than the card: what leaves it
        // is the card's part inside it, 80 px wide.
        let cut = hole.rect.intersection(panel.bounds)
        #expect(abs(cut.width - 80) < 1 && cut.height > 0)
        #expect(abs(pieces.reduce(0) { $0 + $1.width * $1.height }
            - (panel.bounds.width * panel.bounds.height - cut.width * cut.height)) < 2)

        _ = await view.model.respond(to: .sessionInfoOverlays([]))
        #expect(panel.holes.isEmpty)
        #expect(panel.layer?.mask == nil)
        #expect(panel.hitTest(inHole) != nil)
        #expect(panel.uncoveredRects() == [panel.bounds])
    }

    @Test func subtractingAHoleLeavesTheBandsAroundIt() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(AgentPaneSessionInfoPanel.subtract(CGRect(x: 200, y: 0, width: 10, height: 10), from: rect) == [rect])
        let pieces = AgentPaneSessionInfoPanel.subtract(CGRect(x: -20, y: 40, width: 50, height: 20), from: rect)
        #expect(pieces == [
            CGRect(x: 0, y: 0, width: 100, height: 40),
            CGRect(x: 0, y: 60, width: 100, height: 40),
            CGRect(x: 30, y: 40, width: 70, height: 20),
        ])
    }

    /// One structure across the panel (design/grid.md section 3, design/session-info.md's icon
    /// column): every header's and row's icon in one 16 box, every title on one column whether or not
    /// it has an icon, every trailing value on one right edge, a fold row's chevron in the icon column,
    /// and a switch at the row's size. An unstructured panel (a title that starts after its own icon,
    /// an oversized switch) fails here.
    @Test func headersAndRowsShareTheIconTitleAndTrailingColumns() throws {
        var raw = Self.info()
        raw["sections"] = [
            ["id": "environment", "group": "where", "title": "Environment", "bare": true, "open": true, "foldable": false,
             "rows": [
                 ["id": "machine", "symbol": "desktopcomputer", "title": "cosmic-gray", "trailing": "Local"],
                 ["id": "project", "symbol": "folder", "title": "Projects"],
                 ["id": "remote", "symbol": "cursorarrow.rays", "title": "Remote Control", "toggle": true, "action": "remote"],
             ]],
            ["id": "context", "group": "where", "title": "Context", "symbol": "gauge.with.dots.needle.33percent",
             "meta": "32%", "open": true, "foldable": true,
             "rows": [
                 ["id": "free", "symbol": "square.fill", "title": "Free space", "trailing": "44.5K · 11.2%"],
                 ["id": "list:mcp", "symbol": "chevron.right", "title": "MCP tools", "trailing": "4", "action": "context.toggle:mcp"],
                 ["id": "list:skills", "symbol": "chevron.down", "title": "Skills", "trailing": "50", "action": "context.toggle:skills"],
             ]],
            ["id": "changes", "group": "made", "title": "Changes", "meta": "3", "open": true, "foldable": true,
             "rows": [["id": "pr", "symbol": "arrow.triangle.pull", "title": "fix(cmux-tui): server ensure", "trailing": "+220 -2"]]],
            ["id": "tasks", "group": "runs", "title": "Tasks", "meta": "7 done", "open": true, "foldable": true,
             "rows": [
                 ["id": "t1", "title": "Build", "working": true, "trailing": "2s"],
                 ["id": "done", "symbol": "chevron.right", "title": "7 done", "action": "tasks.done"],
             ]],
        ]
        let store = AgentPaneSessionInfoStore()
        let panel = AgentPaneSessionInfoPanel(store: store)
        panel.frame = CGRect(x: 0, y: 0, width: 320, height: 900)
        store.update(try Self.model(raw))
        panel.layoutSubtreeIfNeeded()
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let content = try #require(all(panel).compactMap { $0 as? AgentPaneSessionInfoContent }.first)
        let lines = content.lines
        lines.forEach { $0.layoutSubtreeIfNeeded() }
        #expect(lines.count == 12)
        #expect(lines.contains { $0.line.kind == .header } && lines.contains { $0.line.kind == .row })

        let box = SessionInfoMetrics.iconBox
        let lead = lines[0].frame.minX + SessionInfoMetrics.inset - SessionInfoMetrics.edge
        let text = lines[0].frame.minX + SessionInfoMetrics.text
        let right = lines[0].frame.maxX - SessionInfoMetrics.trail
        #expect(lead == SessionInfoMetrics.inset)
        #expect(text - lead == box + LayoutGrid.gap)
        for line in lines {
            let columns = line.columns
            let x = line.frame.minX
            // Every title starts on one column, a header's or a row's, with an icon or without.
            #expect(abs(x + columns.title.minX - text) < 0.5, "\(line.line.title) title")
            // Every icon centers in the one box at `lead`, no wider than it.
            if let icon = columns.icon {
                #expect(abs(x + icon.midX - (lead + box / 2)) < 0.5, "\(line.line.title) icon")
                #expect(icon.width <= box && icon.height <= box)
            }
            // Every row is a whole step of the 4 grid, a one-line row the grid's 28.
            #expect(line.frame.height.truncatingRemainder(dividingBy: LayoutGrid.base) == 0)
            #expect(line.frame.height >= LayoutGrid.row)
        }
        // A header with an icon puts it in the rows' column too.
        let context = try #require(lines.first { $0.line.id == "context" })
        #expect(context.line.kind == .header && context.columns.icon != nil)

        // Trailing values (a header's meta, a row's value) end on one right edge.
        let trailing = lines.compactMap { line in line.columns.trailing.map { line.frame.minX + $0.maxX } }
        #expect(trailing.count >= 7)
        for edge in trailing { #expect(abs(edge - right) < 0.5) }

        // A fold row's chevron is its icon, at the small glyph size in the icon column.
        let folds = lines.filter(\.line.discloses)
        #expect(folds.map(\.line.title) == ["MCP tools", "Skills", "7 done"])
        for fold in folds {
            let chevron = try #require(fold.columns.icon)
            #expect(abs(fold.frame.minX + chevron.midX - (lead + box / 2)) < 0.5)
            #expect(chevron.width == SessionInfoMetrics.glyph)
        }

        // The switch is the native small size and fits the row; it ends on the trailing edge.
        let remote = try #require(lines.first { $0.line.title == "Remote Control" })
        let toggle = try #require(remote.columns.toggle)
        #expect(toggle.controlSize == .small || toggle.controlSize == .mini)
        #expect(toggle.frame.height <= remote.frame.height - 2 * LayoutGrid.pillInset)
        #expect(abs(remote.frame.minX + toggle.frame.maxX - right) < 0.5)
    }

    /// Changes' rows name cmux pack icons (`cmux:git.pullrequest.merged`, native/changes.ts): the panel draws the pack's template
    /// glyph for them, at 1.2 x the label, and keeps SF Symbols for every other name.
    @Test func changesGlyphsDrawFromTheIconPack() throws {
        for name in ["cmux:git.pullrequest", "cmux:git.pullrequest.merged", "cmux:git.pullrequest.draft", "cmux:git.pullrequest.closed"] {
            let image = try #require(SessionInfoLineView.packIcon(name, font: Typography.body))
            #expect(image.isTemplate)
            #expect(image.size.width == (Typography.body.pointSize * 1.2).rounded())
        }
        #expect(SessionInfoLineView.packIcon("arrow.triangle.merge", font: Typography.body) == nil)
        // A bare name stays an SF Symbol even where the pack has one (Environment's `folder`).
        #expect(SessionInfoLineView.packIcon("folder", font: Typography.body) == nil)
        #expect(SessionInfoLineView.packIcon("cmux:no.such.icon", font: Typography.body) == nil)
    }
}
