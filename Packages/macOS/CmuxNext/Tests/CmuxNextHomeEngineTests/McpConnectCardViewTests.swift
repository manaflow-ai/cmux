import AppKit
import CmuxNextDesign
import CmuxNextHome
import Testing

/// The MCP connect card is AppKit (plans/cmux-next/no-swiftui-DESIGN.md): every look draws with no
/// hosting view; Connect and Cancel run the host's steps; the card shows a new flow in place.
@MainActor @Suite(.serialized) struct McpConnectCardViewTests {
    private final class Steps {
        var connects = 0
        var cancels = 0
        var keys: [String] = []
    }

    private func card(_ auth: McpConnectCard.Auth = .oauth(scopes: ["read"]), verified: Bool = true) -> McpConnectCard {
        McpConnectCard(requestID: "r1", agent: "Chief", reason: "file issues", title: "Linear", publisher: "linear.app",
                       verified: verified, idn: false, transport: .remote(url: "https://mcp.linear.app/mcp"), auth: auth)
    }

    private func make(_ flow: McpConnectCardFlow, style: McpConnectCardStyle, steps: Steps) -> McpConnectCardView {
        let tokens = ThemeTokens.derive(from: ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x1D1F21)))
        let actions = McpConnectCardActions(choose: { _ in }, connect: { steps.connects += 1 }, cancel: { steps.cancels += 1 },
                                            submitKey: { steps.keys.append("\($0)") })
        let view = McpConnectCardView(flow: flow, style: style, colors: McpConnectCardColors(tokens: tokens), actions: actions)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        host.addSubview(view)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                                     view.topAnchor.constraint(equalTo: host.topAnchor),
                                     view.widthAnchor.constraint(equalToConstant: 520)])
        host.layoutSubtreeIfNeeded()
        return view
    }

    private func descendants(of view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }

    private func texts(in view: NSView) -> [String] {
        descendants(of: view).compactMap { ($0 as? NSTextField)?.stringValue }
    }

    private func button(_ id: String, in view: NSView) throws -> NSButton {
        try #require(descendants(of: view).compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "cmux.dialog.button.\(id)" })
    }

    @Test func everyLookDrawsTheCardWithoutHosting() throws {
        for style in McpConnectCardStyle.allCases {
            let view = make(McpConnectCardFlow(card: card()), style: style, steps: Steps())
            #expect(!descendants(of: view).contains { NSStringFromClass(type(of: $0)).contains("NSHostingView") }, "\(style)")
            #expect(view.fittingSize.height > 20, "\(style) drew nothing")
            #expect(view.accessibilityLabel() == McpConnectStrings.connectTitle("Linear"))
        }
    }

    @Test func connectAndCancelRunTheHostsSteps() throws {
        let steps = Steps()
        let view = make(McpConnectCardFlow(card: card()), style: .factsTable, steps: steps)
        try button("connect", in: view).performClick(nil)
        try button("cancel", in: view).performClick(nil)
        #expect(steps.connects == 1)
        #expect(steps.cancels == 1)
        #expect(texts(in: view).contains("mcp.linear.app/mcp") || texts(in: view).contains("https://mcp.linear.app/mcp"))
    }

    @Test func aNewFlowShowsInPlace() throws {
        let steps = Steps()
        var flow = McpConnectCardFlow(card: card())
        let view = make(flow, style: .factsTable, steps: steps)
        _ = flow.connect()
        flow.signedIn()
        flow.connected([McpConnectCard.Tool(name: "list_issues", kind: .read)])
        view.show(flow)
        #expect(view.flow.phase == .connected(tools: [McpConnectCard.Tool(name: "list_issues", kind: .read)]))
        #expect(texts(in: view).contains(McpConnectStrings.connected("Linear", tools: 1, writes: 0)))
        #expect((try? button("connect", in: view)) == nil, "Connect leaves once the card is connected")
    }

    @Test func theKeyFieldSendsTheKeyAndSaveWaitsForOne() throws {
        let steps = Steps()
        var flow = McpConnectCardFlow(card: card(.key(name: "CONTEXT7_API_KEY", optional: false)))
        _ = flow.connect()
        let view = make(flow, style: .factsTable, steps: steps)
        let field = try #require(descendants(of: view).compactMap { $0 as? NSSecureTextField }.first)
        let save = try button("save", in: view)
        #expect(!save.isEnabled)
        field.stringValue = "ctx7sk-secret"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(save.isEnabled)
        save.performClick(nil)
        #expect(steps.keys.count == 1)
        #expect(!steps.keys.contains { $0.contains("secret") }, "a key never prints")
    }

    @Test func detailsOpensTheCompactRowsFacts() throws {
        let view = make(McpConnectCardFlow(card: card()), style: .compactRow, steps: Steps())
        #expect(!texts(in: view).contains(McpConnectStrings.server))
        let details = try #require(descendants(of: view).compactMap { $0 as? NSButton }.first { $0.title == McpConnectStrings.details })
        details.performClick(nil)
        #expect(texts(in: view).contains(McpConnectStrings.server))
    }
}
