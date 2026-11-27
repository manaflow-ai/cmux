import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// A message's links are accessibility links (goal agent-shortcut-found: the onboarding walk and VoiceOver
/// find Chief's welcome link "turn it on" and press it). Each link is a child of its message's element:
/// role link, its shown text as the label, its rect on screen inside the message's, and a press that opens
/// it the way a click does (an app link goes to `onAppLink`, never the system).
@MainActor @Suite(.serialized) struct TranscriptLinkAccessTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let anyApp = "cmux://settings/start-agent-from-any-app"
    static let pr = "https://github.com/manaflow-ai/cmux/pull/1"
    /// The welcome's shortcut list as Chief sends it (ChiefWelcome.text), and a web link.
    static let text = "More shortcuts:\n- `⇧⌘P` Command Palette\n- `⌃⌥⌘Space` Start Agent from Any App (off until you [turn it on](\(anyApp)))\nSee [PR 1](\(pr))."

    private func controller() -> (NSWindow, ChatController) {
        _ = NSApplication.shared
        HomeMarkdownPolicy.install()
        let me = ParticipantID("user_me"), chief = ParticipantID("agent_chief")
        let people = [CmuxHomeCore.Participant(id: me, kind: .human, displayName: "Me"),
                      CmuxHomeCore.Participant(id: chief, kind: .agent, displayName: "Chief", agentClass: .chief)]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let items = [TranscriptItem(key: IdempotencyKey("k1"), seq: Seq(1), author: chief, parts: [.text(Self.text)],
                                    createdAt: base, delivery: .committed, messageID: MessageID("msg_1"))]
        let summary = ConversationSummary(id: ConversationID("conv_ax_links"), title: "Chief", participants: people, lastSeq: 1,
                                          createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
        var core = ProjectionCore(me: me)
        let (conv, w) = core.install(ConversationID("conv_ax_links"), items: items, summary: summary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let controller = ChatController(host: HostView(frame: NSRect(x: 0, y: 0, width: 560, height: 360)), wake: NoWake())
        window.contentView = controller.host
        controller.install(conv, windowStart: w.start, total: w.total)
        controller.host.layoutSubtreeIfNeeded()
        controller.demo?.layoutIfNeeded()
        controller.demo?.collection.layoutIfNeeded()
        return (window, controller)
    }

    private func links(_ message: NSAccessibilityElement) -> [NSAccessibilityElement] {
        (message.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
    }

    @Test func aMessagesMarkdownLinkIsAnAccessibilityLinkInsideTheMessage() throws {
        let (window, controller) = controller()
        let message = try #require(controller.accessibilityElements(parent: controller.host).first)
        #expect(message.isAccessibilityElement())
        let children = links(message)
        #expect(children.map { $0.accessibilityLabel() ?? "" } == ["turn it on", "PR 1"])
        let link = try #require(children.first)
        #expect(link.accessibilityRole() == .link)
        #expect(link.isAccessibilityElement())
        // AXEnabled: without it CuaDriver leaves the link unindexed and the onboarding walk cannot press it.
        #expect(link.isAccessibilityEnabled())
        #expect((link.accessibilityParent() as? NSAccessibilityElement) === message)
        #expect(link.accessibilityURL()?.absoluteString == Self.anyApp)
        let frame = link.accessibilityFrame()
        #expect(frame.width > 10 && frame.height > 10)
        #expect(message.accessibilityFrame().insetBy(dx: -0.5, dy: -0.5).contains(frame))
        // The frame is where a click finds the same link.
        let inHost = controller.host.convert(window.convertFromScreen(frame), from: nil)
        #expect(controller.linkURL(at: CGPoint(x: inHost.midX, y: inHost.midY))?.absoluteString == Self.anyApp)
        withExtendedLifetime(window) {}
    }

    @Test func thePressOpensTheLinkAsAClickDoes() throws {
        let (window, controller) = controller()
        var app: [String] = [], web: [String] = []
        controller.onAppLink = { app.append($0.absoluteString) }
        controller.onOpenLink = { url, _ in web.append(url.absoluteString) }
        let message = try #require(controller.accessibilityElements(parent: controller.host).first)
        let children = links(message)
        try #require(children.count == 2)
        #expect(children[0].accessibilityPerformPress())
        #expect(app == [Self.anyApp])
        #expect(web.isEmpty)
        #expect(children[1].accessibilityPerformPress())
        #expect(web == [Self.pr])
        #expect(app == [Self.anyApp])
        withExtendedLifetime(window) {}
    }

    /// The app.links lines `body` makes `controller` note (ChatController.linkNotes).
    private func notes(_ controller: ChatController, _ body: () throws -> Void) rethrows -> [String] {
        var lines: [String] = []
        controller.linkNotes = { lines.append($0) }
        defer { controller.linkNotes = nil }
        try body()
        return lines
    }

    /// Every press on a link says where it went (goal agent-shortcut-found: run 45968907489's press on
    /// "turn it on" logged nothing, so the walk could not tell what took it). No macro inside another:
    /// the compiler rejects a recursive expansion.
    @Test func aPressSaysWhereTheLinkWent() throws {
        let (window, controller) = controller()
        let message = try #require(controller.accessibilityElements(parent: controller.host).first)
        let link = try #require(links(message).first)
        let ref = PartRef(messageId: "msg_1", partIndex: 0)
        var pressed = false
        var lines = notes(controller) { pressed = link.accessibilityPerformPress() }
        #expect(pressed)
        #expect(lines == ["app link press on settings/start-agent-from-any-app taken by no app link handler: opened nothing"])
        var app: [String] = []
        controller.onAppLink = { app.append($0.absoluteString) }
        lines = notes(controller) { pressed = link.accessibilityPerformPress() }
        #expect(pressed)
        #expect(lines == ["app link press on settings/start-agent-from-any-app handed to the app"])
        #expect(app == [Self.anyApp])
        // A web link goes to the system as before, and says nothing: it is no app link.
        controller.onOpenLink = { _, _ in }
        lines = notes(controller) { pressed = controller.openLink(.text(URL(string: Self.pr)), ref: ref) }
        #expect(pressed)
        #expect(lines.isEmpty)
        lines = notes(controller) { pressed = controller.openLink(.text(nil), ref: ref) }
        #expect(pressed)
        #expect(lines == ["app link press refused by the link policy: opened nothing"])
        lines = notes(controller) { pressed = controller.openLink(.text(URL(string: "cmux://nowhere/x")), ref: ref) }
        #expect(pressed)
        #expect(lines == ["app link press on nowhere/x is no app link: handed to the system"])
        withExtendedLifetime(window) {}
    }

    @Test func aPressOnALinkWhoseTranscriptWentAwaySaysSo() {
        let element = TranscriptLinkElement()
        element.target = .text(URL(string: Self.anyApp))
        #expect(!element.accessibilityPerformPress())
        #expect(TranscriptLinkElement.orphanLine(element.target)
            == "app link press on settings/start-agent-from-any-app taken by no transcript: opened nothing")
    }

    /// A click on the link opens it and says so; a click something before the link takes names the taker.
    @Test func aClickOnTheLinkSaysWhatTookIt() throws {
        let (window, controller) = controller()
        var app: [String] = []
        controller.onAppLink = { app.append($0.absoluteString) }
        let message = try #require(controller.accessibilityElements(parent: controller.host).first)
        let link = try #require(links(message).first)
        let frame = controller.host.convert(window.convertFromScreen(link.accessibilityFrame()), from: nil)
        let p = CGPoint(x: frame.midX, y: frame.midY)
        var lines = notes(controller) { controller.clicked(p) }
        #expect(lines == ["app link press on settings/start-agent-from-any-app handed to the app"])
        #expect(app == [Self.anyApp])
        lines = notes(controller) { controller.noteDroppedLinkClick(at: p, "the thread") }
        #expect(lines == ["app link click on settings/start-agent-from-any-app taken by the thread: opened nothing"])
        // Off any link a taker logs nothing (only a link's click is the walk's question).
        #expect(controller.clickTaker(CGPoint(x: 1, y: 1)) != nil)
        lines = notes(controller) { controller.clicked(CGPoint(x: 1, y: 1)) }
        #expect(lines.isEmpty)
        #expect(app == [Self.anyApp])
        withExtendedLifetime(window) {}
    }

    @Test func theLinkLineNamesTheLinksHostAndPath() {
        #expect(ChatController.linkLine(URL(string: "cmux://settings/start-agent-from-any-app?x=1"), "handed to the app")
            == "app link press on settings/start-agent-from-any-app handed to the app")
        #expect(ChatController.linkLine(nil, "refused") == "app link press refused")
        #expect(ChatController.linkLine(URL(string: "cmux://a/b"), "taken", press: "click") == "app link click on a/b taken")
    }

    /// AppKit advertises no AXPress for this element, so the press is also a named action: CuaDriver
    /// indexes only a node that lists one (the onboarding walk's shortcut/turn-on clicks it by index).
    @Test func eachLinkAdvertisesAnActionThatOpensIt() throws {
        let (window, controller) = controller()
        var app: [String] = []
        controller.onAppLink = { app.append($0.absoluteString) }
        // Two steps: a `#require` inside another is a recursive macro expansion, which the compiler rejects.
        let element = try #require(controller.accessibilityElements(parent: controller.host).first)
        let link = try #require(links(element).first)
        let actions = try #require(link.accessibilityCustomActions())
        #expect(actions.map(\.name) == [CmuxStrings.openLinkAction])
        #expect(actions[0].handler?() == true)
        #expect(app == [Self.anyApp])
        withExtendedLifetime(window) {}
    }

    /// AXActionNames lists AXPress, and performing it opens the link: an AX client (CuaDriver) indexes the
    /// link only when that list is not empty, and the custom action alone left it empty on a Nightly walk.
    @Test func eachLinkListsPressInItsActionNames() throws {
        let (window, controller) = controller()
        var app: [String] = []
        controller.onAppLink = { app.append($0.absoluteString) }
        let element = try #require(controller.accessibilityElements(parent: controller.host).first)
        let link = try #require(links(element).first)
        // Through the Objective-C selector AppKit's AX server calls, not a Swift call, so it reads what a client gets.
        let names = link.perform(NSSelectorFromString("accessibilityActionNames"))?.takeUnretainedValue() as? [String]
        #expect(names?.contains(NSAccessibility.Action.press.rawValue) == true)
        _ = link.perform(NSSelectorFromString("accessibilityPerformAction:"), with: NSAccessibility.Action.press.rawValue)
        #expect(app == [Self.anyApp])
        withExtendedLifetime(window) {}
    }

    @Test func theLinkElementsAreReusedAcrossReads() throws {
        let (window, controller) = controller()
        let first = links(try #require(controller.accessibilityElements(parent: controller.host).first))
        let again = links(try #require(controller.accessibilityElements(parent: controller.host).first))
        #expect(first.count == 2 && again.count == 2)
        #expect(zip(first, again).allSatisfy { $0 === $1 })
        withExtendedLifetime(window) {}
    }

    @Test func aMarkdownLayoutRowsLinkHasItsLabelAndARectAClickHits() throws {
        HomeMarkdownPolicy.install()
        let dest = "https://example.com/guide"
        let source = "> Quoted first.\n\nRead [the guide](\(dest)) before you start."
        let md = MarkdownLayoutEngine.layout(Markdown.parse(source), source: source, maxWidth: Fixture.windowWidth)
        let row = PartRow(ref: PartRef(messageId: "msg_md", partIndex: 0), part: .text(source, runs: []), outgoing: false, tail: true,
                          reactions: [], failed: false, size: md.size, text: md.proxy, connectorRoot: nil, markdown: md, markdownFormat: true)
        let found = row.accessibilityLinks(bodySize: md.size)
        try #require(found.count == 1)
        #expect(found[0].label == "the guide")
        #expect(found[0].target == .text(URL(string: dest)))
        let r = found[0].frame
        #expect(CGRect(origin: .zero, size: md.size).contains(r))
        #expect(md.link(at: CGPoint(x: r.midX, y: r.midY)) == dest)
    }
}
