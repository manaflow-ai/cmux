import AppKit
import CmuxAgentQuestion
@testable import CmuxNextAgentPermissions
import CmuxNextAgentQuestion
@testable import CmuxNextApp
@testable import CmuxNextCookieImport
import CmuxNextDaemonService
import CmuxNextDesign
@testable import CmuxNextSidebar
@testable import CmuxNextTerminal
import CmuxTheme
import Foundation
import Testing

/// The request card gallery (u9380): every card, sheet and panel that asks the person to approve
/// something an agent, a script or the system asked for, in each state, light and dark, at 2x.
/// Each picture goes into `.build/request-cards-gallery/` in the package with `manifest.json`
/// (name, state, source file:line), tarred as `.build/request-cards-gallery.tar`, so a fleet step
/// returns it with `cmux-ci run --artifact Packages/macOS/CmuxNext/.build/request-cards-gallery.tar`.
/// It checks only that every picture is drawn; what the cards say is checked by their own tests
/// (`CloudMachineRequestCardTests` for who asked).
@MainActor @Suite(.serialized) final class RequestCardGalleryTests {
    /// One picture in the gallery.
    struct Shot: Encodable {
        var id: String
        var family: String
        var name: String
        var state: String
        var source: String
        var appearance: String
        var width: Int
        var file: String
        var note: String?
    }

    /// The theme a picture is drawn in.
    struct Look {
        var name: String
        var dark: Bool
        var reduceTransparency = false

        var input: ThemeInput {
            dark ? ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xD4D4D4))
                : ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x24292F))
        }

        static let light = Look(name: "light", dark: false)
        static let dark = Look(name: "dark", dark: true)
        static let both = [light, dark]
    }

    static let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let directory = package.appendingPathComponent(".build/request-cards-gallery")

    private var shots: [Shot] = []
    private var windows: [NSWindow] = []
    private var scopes: [ThemeScope] = []

    // MARK: Drawing

    /// Draws `view` (laid out by `place` in a root of `size`) in `look` at 2x and records it.
    private func shoot(_ family: String, _ name: String, state: String, source: String, look: Look, size: NSSize,
                                note: String? = nil, view: NSView, place: (NSView, NSView) -> Void) throws {
        let pinned = ReduceTransparency.shared.override
        ReduceTransparency.shared.override = look.reduceTransparency
        defer { ReduceTransparency.shared.override = pinned }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: look.dark ? .darkAqua : .aqua)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(srgbRed: CGFloat(look.input.background.red), green: CGFloat(look.input.background.green),
                                              blue: CGFloat(look.input.background.blue), alpha: 1).cgColor
        window.contentView = root
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(look.dark ? "Dark+" : "GitHub Light"), input: look.input, animated: false)
        scope.root(root)
        scopes.append(scope)
        windows.append(window)
        root.addSubview(view)
        place(root, view)
        for _ in 0..<3 {
            root.needsLayout = true
            root.layoutSubtreeIfNeeded()
            Self.refresh(view)
        }
        root.displayIfNeeded()
        let png = try #require(Self.png(root), "\(name) drew nothing")
        let id = String(format: "%03d", shots.count + 1)
        let slug = (family + "-" + name + "-" + state + "-" + look.name + "-\(Int(size.width))")
            .lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { $0.append($1) }
        let file = "\(id)-\(slug).png"
        try png.write(to: Self.directory.appendingPathComponent(file))
        shots.append(Shot(id: id, family: family, name: name, state: state, source: source,
                          appearance: look.name + (look.reduceTransparency ? " · Reduce Transparency" : ""),
                          width: Int(size.width), file: file, note: note))
    }

    /// Every view below `view` re-reads its theme colors in the window it now sits in.
    private static func refresh(_ view: NSView) {
        view.viewDidChangeEffectiveAppearance()
        view.needsDisplay = true
        view.subviews.forEach(refresh)
    }

    /// `view` at 2x, whatever the screen's scale.
    private static func png(_ view: NSView) -> Data? {
        let size = view.bounds.size
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: Sidebar request card

    static let machine = CloudMachineCreateFlow.Machine(name: "builder", cpu: 2, memoryMB: 4096, diskMB: 16384)

    /// The card the real request path builds (``CloudPresenter/confirmCreate``), and its open question.
    private func askCard(_ services: AppServices, _ machine: CloudMachineCreateFlow.Machine, window: NSWindow,
                         requester: CookieImportRequester?) async throws -> (SidebarNoticeCard, Task<Bool, Never>) {
        let asks = services.machineAsks
        let answer = Task { await CloudPresenter.confirmCreate(.agentRequest(machine), in: window, asks: asks, requester: { _ in requester }, reveal: { _ in }) }
        let deadline = ContinuousClock.now + .seconds(5)
        while asks.card == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5)) // test-only: waits for the request's task, bounded
        }
        return (try #require(asks.card, "no request card"), answer)
    }

    /// `card` in the sidebar, above its footer, as the window shows it.
    private func shootSidebar(_ name: String, state: String, card: SidebarNoticeCard, look: Look, width: CGFloat,
                                       source: String, note: String? = nil) async throws {
        let model = SidebarModel()
        let sidebar = SidebarView(model: model, design: DesignSettings())
        let height = SidebarNoticeCardView.height(for: card) + 120
        model.noticeCard = card
        try shoot("Sidebar card", name, state: state, source: source, look: look, size: NSSize(width: width, height: height), note: note,
                  view: sidebar) { root, view in view.frame = root.bounds }
        let deadline = ContinuousClock.now + .seconds(5)
        while !sidebar.cardSlot.showsNotice, ContinuousClock.now < deadline {
            sidebar.needsLayout = true
            sidebar.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(5)) // test-only: waits for the sidebar's model task, bounded
        }
        #expect(sidebar.cardSlot.showsNotice, "\(name): the sidebar shows no card")
        // Drawn again now that the card is in its slot.
        shots.removeLast()
        try shoot("Sidebar card", name, state: state, source: source, look: look, size: NSSize(width: width, height: height), note: note,
                  view: sidebar) { root, view in view.frame = root.bounds }
    }

    private func sidebarCards(_ services: AppServices, window: NSWindow) async throws {
        let cardSource = "Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Views/SidebarNoticeCardView.swift:15"
        let askSource = "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Cloud/CloudService+AppServer.swift:92"
        // Before (feat-cmux-next 8d0ef6ea71b): one fixed line that names no one.
        var before = SidebarNoticeCard(id: "ask.before", symbol: "cloud", title: CloudStrings.createConfirmTitle,
                                       detail: "Asked by an agent or a script. It counts against your Cloud plan.",
                                       lines: [CloudStrings.createConfirmName("builder"), CloudStrings.createConfirmSize(cpu: 2, memoryGB: 4, diskGB: 16)],
                                       actions: [.init(id: "yes", title: CloudStrings.createConfirmButton, prominent: true), .init(id: "no", title: CloudStrings.cancel)],
                                       dismissLabel: CloudStrings.cancel)
        before.awaitsAnswer = true
        for look in Look.both {
            try await shootSidebar("Create a Cloud machine (before)", state: "pending", card: before, look: look, width: Metrics.sidebarWidth,
                                   source: askSource, note: "Old copy: says only 'Asked by an agent or a script'.")
        }
        let chat = CookieImportRequester(kind: .agentChat, name: "a412 · cloud groups", workspace: "Home & chat", tabID: "tab-412")
        let terminal = CookieImportRequester(kind: .terminal, name: "zsh — ~/fun/cmux", workspace: "cmux-next app", tabID: "tab-7")
        let long = CookieImportRequester(kind: .agentChat, name: "a480 · Request card variants gallery and requester attribution",
                                         workspace: "Agents & routing — overflow test", tabID: "tab-480")
        var fromChat = Self.machine
        fromChat.askedBy = CloudMachineCreateFlow.Asker(session: "sess-412")
        var fromTerminal = Self.machine
        fromTerminal.askedBy = CloudMachineCreateFlow.Asker(session: nil, terminal: "term-7")
        var closedChat = Self.machine
        closedChat.askedBy = CloudMachineCreateFlow.Asker(session: "019a3f2c-7d1e-7b8a-9c41-5e2f0d6a7b13")
        var legacy = CloudMachineCreateFlow.named(nil, sizeShown: false)
        legacy.askedBy = fromChat.askedBy
        var unnamed = CloudMachineCreateFlow.named(nil)
        unnamed.askedBy = fromChat.askedBy
        let variants: [(String, CloudMachineCreateFlow.Machine, CookieImportRequester?, [CGFloat], String?)] = [
            ("Create a Cloud machine · agent chat", fromChat, chat, [200, Metrics.sidebarWidth, 360], "Requester line opens the chat (tab.focus)."),
            ("Create a Cloud machine · terminal CLI", fromTerminal, terminal, [Metrics.sidebarWidth], "Requester line opens the terminal tab."),
            ("Create a Cloud machine · program outside cmux", Self.machine, nil, [Metrics.sidebarWidth], "No caller named itself: plain text, nothing to open."),
            ("Create a Cloud machine · chat not open here", closedChat, nil, [Metrics.sidebarWidth], "Caller's session id only: no open tab to open."),
            ("Create a Cloud machine · long names", fromChat, long, [200, Metrics.sidebarWidth], "Requester line truncates; tooltip has it all."),
            ("Create a Cloud machine · legacy create (no size)", legacy, chat, [Metrics.sidebarWidth], "The legacy /api/vm path: the plan picks the size."),
            ("Create a Cloud machine · no name", unnamed, chat, [Metrics.sidebarWidth], nil),
        ]
        for (name, machine, requester, widths, note) in variants {
            let (card, answer) = try await askCard(services, machine, window: window, requester: requester)
            for width in widths {
                for look in Look.both {
                    try await shootSidebar(name, state: "pending", card: card, look: look, width: width, source: askSource, note: note)
                }
            }
            if name.hasSuffix("agent chat") {
                for look in Look.both {
                    var opaque = look
                    opaque.reduceTransparency = true
                    try await shootSidebar(name, state: "pending", card: card, look: opaque, width: Metrics.sidebarWidth, source: cardSource, note: note)
                }
                // A second request waits behind it: the card shows the oldest only, and nothing says another waits.
                let (_, second) = try await askCard(services, fromTerminal, window: window, requester: terminal)
                try await shootSidebar(name, state: "2 queued", card: card, look: .dark, width: Metrics.sidebarWidth, source: askSource,
                                       note: "Two requests queued: only the oldest shows; no count. (Not changed here.)")
                second.cancel()
            }
            answer.cancel()
            let deadline = ContinuousClock.now + .seconds(5)
            while services.machineAsks.card != nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5)) // test-only: the cancel hops to the main actor, bounded
            }
        }
    }

    // MARK: Dialogs

    private func dialog(_ name: String, state: String, source: String, spec: CmuxDialogSpec, note: String? = nil) throws {
        for look in Look.both {
            let view = CmuxDialogView(spec: spec)
            try shoot("Dialog", name, state: state, source: source, look: look, size: NSSize(width: 520, height: 340), note: note, view: view) { root, view in
                NSLayoutConstraint.activate([
                    view.centerXAnchor.constraint(equalTo: root.centerXAnchor), view.centerYAnchor.constraint(equalTo: root.centerYAnchor),
                    view.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
                ])
            }
        }
    }

    private func dialogs() throws {
        let lines = [CloudStrings.createConfirmName("builder"), CloudStrings.createConfirmSize(cpu: 2, memoryGB: 4, diskGB: 16)]
        let chat = CookieImportRequester(kind: .agentChat, name: "a412 · cloud groups", workspace: "Home & chat", tabID: "tab-412")
        let asker = CloudPresenter.askerLine(CloudMachineCreateFlow.Asker(session: "sess-412"), requester: { _ in chat }).line.text
        let cloud = { (body: [String]) in
            CmuxDialogSpec(title: CloudStrings.createConfirmTitle, lines: [body.joined(separator: "\n")],
                           buttons: [.cancel(CloudStrings.cancel), CmuxDialogButton(id: "confirm", title: CloudStrings.createConfirmButton, role: .default)],
                           identifier: CloudPresenter.createConfirmIdentifier)
        }
        let cloudSource = "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Cloud/CloudPresenter.swift:58"
        try dialog("Create a Cloud machine sheet (before)", state: "sidebar hidden", source: cloudSource,
                   spec: cloud(["Asked by an agent or a script. It counts against your Cloud plan."] + lines),
                   note: "Shown instead of the card when the window's sidebar is hidden.")
        try dialog("Create a Cloud machine sheet", state: "sidebar hidden", source: cloudSource, spec: cloud([asker, CloudStrings.createRequestDetail] + lines),
                   note: "Names the requester as the card does (no link in a sheet).")
        try dialog("Approve a held Cloud machine", state: "backend approval", source: cloudSource,
                   spec: cloud([CloudStrings.createConfirmApproval] + lines), note: "The person's own create the backend held: no requester.")
        let clipboardSource = "Packages/macOS/CmuxNext/Sources/CmuxNextApp/ClipboardReads/ClipboardReadStrings.swift:48"
        try dialog("Clipboard read", state: "known host", source: clipboardSource, spec: ClipboardReadStrings.spec(terminal: "zsh — ~/fun/cmux", host: "cmux-lawrences-mac-mini"))
        try dialog("Clipboard read", state: "unknown origin", source: clipboardSource, spec: ClipboardReadStrings.spec(terminal: "zsh — ~/fun/cmux", host: nil))
        let osc52 = "Packages/macOS/CmuxNext/Sources/CmuxNextTerminal/TerminalClipboardRequests.swift:206"
        try dialog("Clipboard write (OSC 52)", state: "pending", source: osc52,
                   spec: TerminalClipboardRequests.spec("Allow a program to change the clipboard?",
                                                        "A program running in this terminal wants to copy text to the clipboard.",
                                                        preview: "export CMUX_TOKEN=…\ngit push origin feat-cmux-next"),
                   note: "English defaults (the module's localized title and message).")
        try dialog("Paste with line breaks", state: "pending", source: osc52,
                   spec: TerminalClipboardRequests.spec("Paste into the terminal?", "The text contains line breaks and may run commands immediately.",
                                                        preview: "rm -rf build\n./scripts/reload.sh --tag x"))
        try dialog("Pair a daemon", state: "pending", source: "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Pairing/DaemonPairingStrings.swift:39",
                   spec: DaemonPairingStrings.spec(code: "482 913", peer: "cmux-lawrences-mac-mini"))
        try dialog("Destructive confirm", state: "with don't ask again", source: "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Handlers/DestructiveConfirmation.swift:173",
                   spec: DestructiveConfirmation.spec(.init(title: "Close Workspace?", body: "3 terminals are running programs. They stop when the workspace closes.",
                                                            button: "Close", suppresses: ["app", "confirmClose"])),
                   note: "Example text; names no requester even when an agent ran the action.")
    }

    // MARK: Mac Requests

    private func macRequests() throws {
        let source = "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPermissions/UI/PermissionRequestCardView.swift:65"
        let claimed = PermissionRequester(agentName: "a412", agentID: "sess-412", workspaceName: "Home & chat", workspaceID: "ws_1")
        let verified = PermissionRequester(agentName: "a412 · cloud groups", agentID: "sess-412", workspaceName: "Home & chat", workspaceID: "ws_1", isClaimed: false)
        let screen = PermissionRequest(kind: .screenRecording, reason: "Take screenshots of the request cards for the gallery.",
                                       prompt: "take a bunch of screenshots of every window variant", requester: verified)
        let unclear = PermissionRequest(kind: .accessibility, reason: "Need it.", prompt: "fix the sidebar lag", requester: claimed)
        let computer = PermissionRequest(kind: .computerUse, reason: "Click through the Cloud create flow to check the card.",
                                         prompt: nil, requester: verified)
        var guiding = PendingPermissionRequest(id: "perm_3", request: computer)
        guiding.phase = .guiding
        guiding.guidingGrant = .accessibility
        let cases: [(String, PendingPermissionRequest?, Int, PendingPermissionRequest?, String?)] = [
            ("Screen Recording · verified agent", PendingPermissionRequest(id: "perm_1", request: screen), 0, nil, nil),
            ("Accessibility · claimed name, unclear reason", PendingPermissionRequest(id: "perm_2", request: unclear), 2, nil, "2 more wait behind it."),
            ("Computer Use · guiding", guiding, 0, nil, nil),
            ("Screen Recording · granted", nil, 0, PendingPermissionRequest(id: "perm_1", request: screen), nil),
        ]
        for (name, request, waiting, granted, note) in cases {
            for look in Look.both {
                let card = PermissionRequestCardView(actions: .init(deny: {}, proceed: {}, close: {}), appURL: { _ in Bundle.main.bundleURL })
                card.render(request, waiting: waiting, granted: granted)
                let size = card.fittingSize
                try shoot("Mac Requests", name, state: request?.phase.rawValue ?? "granted", source: source, look: look,
                          size: NSSize(width: max(size.width, 300) + 40, height: max(size.height, 80) + 40), note: note, view: card) { root, view in
                    view.translatesAutoresizingMaskIntoConstraints = false
                    NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
                                                 view.topAnchor.constraint(equalTo: root.topAnchor, constant: 20)])
                }
            }
        }
    }

    // MARK: Cookie import consent

    private func cookiePanels() throws {
        let source = "Packages/macOS/CmuxNext/Sources/CmuxNextCookieImport/CookieImportConsentPanel.swift:15"
        let cases: [(String, CookieImportRequester, Bool, [String])] = [
            ("agent chat · Chrome · 2 sites", CookieImportRequester(kind: .agentChat, name: "a440 · AWS profiles", workspace: "Agents & routing", tabID: "tab-440",
                                                                   latestMessage: "I will sign in to the AWS console in your Work profile."), false, ["aws.amazon.com", "signin.aws.amazon.com"]),
            ("terminal · Safari · every cookie", CookieImportRequester(kind: .terminal, name: "zsh — ~/fun/cmux", workspace: "cmux-next app", tabID: "tab-7"), true, []),
            ("program outside cmux", CookieImportRequester(kind: .unknown, name: ""), false, ["github.com"]),
        ]
        for (name, requester, safari, domains) in cases {
            for look in Look.both {
                let request = CookieImportRequest(requester: requester, reason: "Sign in to check the deploy.", source: safari ? "Safari" : "Google Chrome · Work",
                                                  sourceIsSafari: safari, domains: domains, target: "Work")
                let panel = CookieImportConsentPanel(request: request, onShowRequester: requester.tabID == nil ? nil : {})
                let content = try #require(panel.builtPanel.contentView)
                let size = panel.builtPanel.frame.size
                content.removeFromSuperview()
                try shoot("Cookie import", name, state: "pending", source: source, look: look, size: size, view: content) { root, view in
                    view.translatesAutoresizingMaskIntoConstraints = true
                    view.frame = root.bounds
                }
            }
        }
    }

    // MARK: Agent question card

    private func questions() throws {
        let source = "Packages/macOS/CmuxNext/Sources/CmuxNextAgentQuestion/AgentQuestionCardView.swift:88"
        for name in AgentQuestionFixture.names.prefix(6) {
            let question = try AgentQuestionFixture(name: name).question
            for look in Look.both {
                let card = AgentQuestionCardView(frame: NSRect(x: 0, y: 0, width: 420, height: 10))
                card.configure(question: question, width: 420)
                let height = max(card.fittingSize.height, card.frame.height, 80)
                try shoot("Agent question", name, state: "\(question.state)", source: source, look: look, size: NSSize(width: 460, height: height + 40),
                          note: "Not wired into the app yet (nothing outside its module creates it).", view: card) { root, view in
                    view.frame = NSRect(x: 20, y: 20, width: 420, height: height)
                }
            }
        }
    }

    // MARK: The gallery

    @Test func drawsEveryRequestCardVariant() async throws {
        _ = NSApplication.shared
        try? FileManager.default.removeItem(at: Self.directory)
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let services = AppServices(environment: AppEnvironment.current([:]))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            window.close()
            windows.forEach { $0.close() }
        }
        try await sidebarCards(services, window: window)
        try dialogs()
        try macRequests()
        try cookiePanels()
        try questions()
        #expect(shots.count > 40, "the gallery drew \(shots.count) pictures")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(shots).write(to: Self.directory.appendingPathComponent("manifest.json"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-cf", Self.package.appendingPathComponent(".build/request-cards-gallery.tar").path, "-C", Self.package.appendingPathComponent(".build").path, "request-cards-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0, "tar failed")
    }
}
