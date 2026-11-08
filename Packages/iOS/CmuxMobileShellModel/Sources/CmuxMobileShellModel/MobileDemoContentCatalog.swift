import CMUXMobileCore
public import Foundation

/// The canned content behind the demonstration computer.
///
/// One demonstration Mac with realistic developer workspaces (agent task rows
/// with statuses, terminals with recorded-style session history) and sample
/// notification-feed entries. The values are ordinary shell models — the same
/// `MobileWorkspacePreview` / `MobileNotificationFeedItem` shapes a live Mac
/// produces — so they flow through the production stores, aggregation, and
/// views unchanged. Sample workspace and terminal content is intentionally
/// plain English developer content; only interface chrome (the computer's
/// display name) is localized.
public struct MobileDemoContentCatalog: Sendable {
    /// The namespace prefix every demonstration identifier carries (the
    /// computer, workspaces, terminals, surfaces, notifications). Real Mac
    /// identifiers are hardware-derived UUIDs, so this prefix is a stable
    /// ownership signal that survives any session or app lifecycle.
    public static let identifierPrefix = "cmux-demo-"

    /// Whether an identifier belongs to the demonstration namespace.
    public static func ownsIdentifier(_ identifier: String) -> Bool {
        identifier.hasPrefix(identifierPrefix)
    }

    /// The demonstration computer's stable device identifier. Prefixed so it
    /// can never collide with a real Mac's hardware-derived identifier.
    public static let macDeviceID = "cmux-demo-mac"

    /// The demonstration computer's user-facing name.
    public static var displayName: String {
        String(localized: "mobile.demo.computerName", defaultValue: "Demo Mac")
    }

    /// This Mac's workspaces, already stamped with the demo device id.
    public let workspaces: [MobileWorkspacePreview]
    /// Sample notification-feed entries, newest first.
    public let notifications: [MobileNotificationFeedItem]
    /// The canned terminal sessions backing every demo terminal surface.
    public let terminalScripts: [MobileDemoTerminalScript]

    /// Builds the standard demonstration catalog.
    /// - Parameter now: The reference time used for relative activity
    ///   timestamps; injected so tests are deterministic.
    public static func standard(now: Date = Date()) -> MobileDemoContentCatalog {
        MobileDemoContentCatalog(now: now)
    }

    private init(now: Date) {
        func minutesAgo(_ minutes: Int) -> Date {
            now.addingTimeInterval(TimeInterval(-60 * minutes))
        }

        let mac = Self.macDeviceID
        let macName = Self.displayName

        // MARK: Workspaces

        let reviewTodo = MobileTodoSnapshot(
            status: .review,
            statusHidden: false,
            items: [
                MobileTodoItem(
                    id: "cmux-demo-todo-review-1",
                    text: "Read the PR #412 diff",
                    state: .completed,
                    origin: .agent
                ),
                MobileTodoItem(
                    id: "cmux-demo-todo-review-2",
                    text: "Run the webhook test suite",
                    state: .completed,
                    origin: .agent
                ),
                MobileTodoItem(
                    id: "cmux-demo-todo-review-3",
                    text: "Draft the review summary",
                    state: .inProgress,
                    origin: .agent
                ),
                MobileTodoItem(
                    id: "cmux-demo-todo-review-4",
                    text: "File the delivery-metrics follow-up",
                    state: .pending,
                    origin: .user
                ),
            ]
        )
        let releaseTodo = MobileTodoSnapshot(
            status: .working,
            statusHidden: false,
            items: [
                MobileTodoItem(
                    id: "cmux-demo-todo-release-1",
                    text: "Bump version to 2.3.1",
                    state: .completed,
                    origin: .user
                ),
                MobileTodoItem(
                    id: "cmux-demo-todo-release-2",
                    text: "Archive the release build",
                    state: .inProgress,
                    origin: .agent
                ),
                MobileTodoItem(
                    id: "cmux-demo-todo-release-3",
                    text: "Upload debug symbols",
                    state: .pending,
                    origin: .agent
                ),
            ]
        )
        let docsTodo = MobileTodoSnapshot(
            status: .done,
            statusHidden: false,
            items: [
                MobileTodoItem(
                    id: "cmux-demo-todo-docs-1",
                    text: "Rewrite the getting-started guide",
                    state: .completed,
                    origin: .agent
                ),
                MobileTodoItem(
                    id: "cmux-demo-todo-docs-2",
                    text: "Publish the docs site",
                    state: .completed,
                    origin: .user
                ),
            ]
        )

        workspaces = [
            MobileWorkspacePreview(
                id: MobileWorkspacePreview.ID(rawValue: "cmux-demo-ws-review"),
                macDeviceID: mac,
                macDisplayName: macName,
                name: "Webhook retries",
                currentDirectory: "~/code/api-server",
                previewText: "Agent: review ready — 4 files changed, 48 tests green",
                previewAt: minutesAgo(12),
                lastActivityAt: minutesAgo(12),
                hasUnread: true,
                unreadCount: 2,
                terminals: [
                    MobileTerminalPreview(
                        id: MobileTerminalPreview.ID(rawValue: "cmux-demo-term-review-agent"),
                        name: "Agent",
                        currentDirectory: "~/code/api-server",
                        isFocused: true
                    ),
                    MobileTerminalPreview(
                        id: MobileTerminalPreview.ID(rawValue: "cmux-demo-term-review-tests"),
                        name: "Tests",
                        currentDirectory: "~/code/api-server"
                    ),
                ],
                surfaces: [
                    MobileSurfacePreview(
                        id: MobileSurfacePreview.ID(rawValue: "cmux-demo-surface-review-todo"),
                        kind: .todo,
                        title: "Tasks",
                        todo: reviewTodo
                    ),
                ]
            ),
            MobileWorkspacePreview(
                id: MobileWorkspacePreview.ID(rawValue: "cmux-demo-ws-release"),
                macDeviceID: mac,
                macDisplayName: macName,
                name: "Release 2.3.1",
                currentDirectory: "~/code/mobile-app",
                previewText: "Build succeeded in 4m 02s, 312 tests passed",
                previewAt: minutesAgo(87),
                lastActivityAt: minutesAgo(87),
                hasUnread: false,
                terminals: [
                    MobileTerminalPreview(
                        id: MobileTerminalPreview.ID(rawValue: "cmux-demo-term-release-build"),
                        name: "Build",
                        currentDirectory: "~/code/mobile-app",
                        isFocused: true
                    ),
                    MobileTerminalPreview(
                        id: MobileTerminalPreview.ID(rawValue: "cmux-demo-term-release-shell"),
                        name: "Shell",
                        currentDirectory: "~/code/mobile-app"
                    ),
                ],
                surfaces: [
                    MobileSurfacePreview(
                        id: MobileSurfacePreview.ID(rawValue: "cmux-demo-surface-release-todo"),
                        kind: .todo,
                        title: "Tasks",
                        todo: releaseTodo
                    ),
                ]
            ),
            MobileWorkspacePreview(
                id: MobileWorkspacePreview.ID(rawValue: "cmux-demo-ws-docs"),
                macDeviceID: mac,
                macDisplayName: macName,
                name: "Docs site",
                currentDirectory: "~/code/docs",
                previewText: "Getting-started guide rewritten for the new pairing flow",
                previewAt: minutesAgo(174),
                lastActivityAt: minutesAgo(174),
                hasUnread: false,
                terminals: [
                    MobileTerminalPreview(
                        id: MobileTerminalPreview.ID(rawValue: "cmux-demo-term-docs-dev"),
                        name: "Dev server",
                        currentDirectory: "~/code/docs",
                        isFocused: true
                    ),
                ],
                surfaces: [
                    MobileSurfacePreview(
                        id: MobileSurfacePreview.ID(rawValue: "cmux-demo-surface-docs-todo"),
                        kind: .todo,
                        title: "Tasks",
                        todo: docsTodo
                    ),
                ]
            ),
        ]

        // MARK: Notifications (newest first)

        notifications = [
            MobileNotificationFeedItem(
                macDeviceID: mac,
                notificationID: "cmux-demo-notif-review-ready",
                macDisplayName: macName,
                remoteWorkspaceID: "cmux-demo-ws-review",
                remoteSurfaceID: "cmux-demo-term-review-agent",
                title: "Agent finished",
                body: "Webhook retry PR is ready for review — 4 files changed, 48 tests green.",
                createdAt: minutesAgo(12),
                isRead: false,
                workspaceTitle: "Webhook retries",
                surfaceTitle: "Agent",
                connectionStatus: .connected
            ),
            MobileNotificationFeedItem(
                macDeviceID: mac,
                notificationID: "cmux-demo-notif-approval",
                macDisplayName: macName,
                remoteWorkspaceID: "cmux-demo-ws-review",
                remoteSurfaceID: "cmux-demo-term-review-agent",
                title: "Needs approval",
                body: "Run database migration 0043_add_delivery_metrics on staging?",
                createdAt: minutesAgo(41),
                isRead: false,
                workspaceTitle: "Webhook retries",
                surfaceTitle: "Agent",
                connectionStatus: .connected
            ),
            MobileNotificationFeedItem(
                macDeviceID: mac,
                notificationID: "cmux-demo-notif-build",
                macDisplayName: macName,
                remoteWorkspaceID: "cmux-demo-ws-release",
                remoteSurfaceID: "cmux-demo-term-release-build",
                title: "Build succeeded",
                body: "Release 2.3.1 archived in 4m 02s, 312 tests passed.",
                createdAt: minutesAgo(87),
                isRead: true,
                workspaceTitle: "Release 2.3.1",
                surfaceTitle: "Build",
                connectionStatus: .connected
            ),
            MobileNotificationFeedItem(
                macDeviceID: mac,
                notificationID: "cmux-demo-notif-tests",
                macDisplayName: macName,
                remoteWorkspaceID: "cmux-demo-ws-review",
                remoteSurfaceID: "cmux-demo-term-review-tests",
                title: "Tests green",
                body: "Session-restore race regression test now passes on CI.",
                createdAt: minutesAgo(163),
                isRead: true,
                workspaceTitle: "Webhook retries",
                surfaceTitle: "Tests",
                connectionStatus: .connected
            ),
            MobileNotificationFeedItem(
                macDeviceID: mac,
                notificationID: "cmux-demo-notif-docs",
                macDisplayName: macName,
                remoteWorkspaceID: "cmux-demo-ws-docs",
                remoteSurfaceID: "cmux-demo-term-docs-dev",
                title: "Docs deployed",
                body: "Getting-started guide published to the docs site.",
                createdAt: minutesAgo(1_294),
                isRead: true,
                workspaceTitle: "Docs site",
                surfaceTitle: "Dev server",
                connectionStatus: .connected
            ),
        ]

        // MARK: Terminal sessions

        func vt(_ text: String) -> String {
            text.replacingOccurrences(of: "\n", with: "\r\n")
        }
        func prompt(_ directory: String) -> String {
            "\u{1B}[1;32mdemo@demo-mac\u{1B}[0m \u{1B}[1;36m\(directory)\u{1B}[0m % "
        }

        let green = "\u{1B}[32m"
        let dim = "\u{1B}[2m"
        let bold = "\u{1B}[1m"
        let cyan = "\u{1B}[36m"
        let reset = "\u{1B}[0m"

        // Coherent fake project trees so cd/ls/pwd/cat compose: `cd src`,
        // `ls`, `cat deliver.ts`, `cd ..` all behave like a real checkout.
        let apiServerTree = MobileDemoDirectory([
            .directory(name: "src", MobileDemoDirectory([
                .directory(name: "webhooks", MobileDemoDirectory([
                    .file(
                        name: "deliver.ts",
                        contents: "export async function deliver(event: WebhookEvent) {\n" +
                            "  const attempt = await queue.nextAttempt(event);\n" +
                            "  return send(event.endpoint, event.payload, attempt);\n}"
                    ),
                    .file(
                        name: "retry.ts",
                        contents: "// Exponential backoff with jitter: 1s -> 2s -> 4s,\n" +
                            "// parking after five failed attempts.\n" +
                            "export const schedule = backoff({ base: 1_000, factor: 2, maxAttempts: 5 });"
                    ),
                ])),
                .file(
                    name: "server.ts",
                    contents: "import { router } from \"./router\";\n\nlisten(router, { port: 8080 });"
                ),
            ])),
            .directory(name: "tests", MobileDemoDirectory([
                .file(
                    name: "webhooks.test.ts",
                    contents: "test(\"retries with exponential backoff after 500\", async () => {\n" +
                        "  const outcome = await deliverWithFailures(2);\n" +
                        "  expect(outcome.attempts).toEqual([1_000, 2_000, 4_000]);\n});"
                ),
            ])),
            .file(
                name: "README.md",
                contents: "# api-server\n\nWebhook delivery service.\nRun `npm test` before opening a PR."
            ),
            .file(
                name: "package.json",
                contents: "{\n  \"name\": \"api-server\",\n  \"version\": \"1.8.0\"\n}"
            ),
        ])
        let mobileAppTree = MobileDemoDirectory([
            .directory(name: "Sources", MobileDemoDirectory([
                .file(
                    name: "App.swift",
                    contents: "@main\nstruct MobileApp: App {\n  var body: some Scene { WindowGroup { RootView() } }\n}"
                ),
                .file(
                    name: "PushCoordinator.swift",
                    contents: "// Uploads the device token only after notifications are enabled."
                ),
            ])),
            .directory(name: "Tests", MobileDemoDirectory([
                .file(
                    name: "AppTests.swift",
                    contents: "@Test func coldLaunchRestoresLastWorkspace() { /* 312 tests total */ }"
                ),
            ])),
            .file(
                name: "CHANGELOG.md",
                contents: "## 2.3.1\n- Faster cold launch\n- Webhook delivery metrics"
            ),
        ])
        let docsTree = MobileDemoDirectory([
            .directory(name: "pages", MobileDemoDirectory([
                .file(
                    name: "getting-started.md",
                    contents: "# Getting started\n\nPair your phone from Settings > Devices."
                ),
                .file(
                    name: "pairing.md",
                    contents: "# Pairing\n\nScan the QR code shown on your computer."
                ),
                .file(
                    name: "notifications.md",
                    contents: "# Notifications\n\nAgents can notify your phone when a task finishes."
                ),
            ])),
            .directory(name: "public", MobileDemoDirectory([
                .file(name: "logo.svg", contents: nil),
            ])),
            .file(
                name: "package.json",
                contents: "{\n  \"name\": \"docs\",\n  \"version\": \"0.9.2\"\n}"
            ),
        ])

        let agentTranscript = vt("""
        \(prompt("~/code/api-server"))cmux agent "review PR #412: webhook retry with exponential backoff"
        \(dim)session started · claude\(reset)
        \(cyan)●\(reset) Reading src/webhooks/deliver.ts
        \(cyan)●\(reset) Reading src/webhooks/retry.ts
        \(cyan)●\(reset) Running npm test -- webhooks
        \(green)✓\(reset) 48 tests passed in 6.2s
        \(bold)Summary\(reset)
        The retry queue now backs off 1s → 2s → 4s with jitter and gives up after
        five attempts, parking failed deliveries in the dead-letter table. Error
        handling around partial JSON responses is covered by two new tests.
        \(green)4 files changed\(reset) · +182 −37 · all tests passing
        \(dim)session complete · review posted to PR #412\(reset)

        """)

        let testsTranscript = vt("""
        \(prompt("~/code/api-server"))npm test -- webhooks
        \(dim)> api-server@1.8.0 test\(reset)
        \(green)✓\(reset) delivers webhook on first attempt (112 ms)
        \(green)✓\(reset) retries with exponential backoff after 500 (441 ms)
        \(green)✓\(reset) adds jitter between attempts (87 ms)
        \(green)✓\(reset) parks delivery after five failures (203 ms)
        \(green)✓\(reset) resumes parked deliveries on demand (154 ms)
        \(bold)Test suites: 6 passed\(reset), 48 tests passed, 0 failed

        """)

        let buildTranscript = vt("""
        \(prompt("~/code/mobile-app"))make release
        \(dim)▸ Resolving package dependencies\(reset)
        \(dim)▸ Compiling AppCore (214 files)\(reset)
        \(dim)▸ Compiling AppUI (156 files)\(reset)
        \(dim)▸ Linking mobile-app\(reset)
        \(dim)▸ Running test suite\(reset)
        \(green)✓ 312 tests passed\(reset)
        \(bold)\(green)Build succeeded\(reset) in 4m 02s
        Archive written to build/release/mobile-app-2.3.1.xcarchive

        """)

        let shellTranscript = vt("""
        \(prompt("~/code/mobile-app"))git status
        On branch main
        Your branch is up to date with 'origin/main'.

        nothing to commit, working tree clean

        """)

        let docsTranscript = vt("""
        \(prompt("~/code/docs"))npm run build
        \(dim)> docs@0.9.2 build\(reset)
        \(dim)Rendering 42 pages…\(reset)
        \(green)✓\(reset) getting-started.md
        \(green)✓\(reset) pairing.md
        \(green)✓\(reset) notifications.md
        \(bold)Built 42 pages in 3.4s\(reset)

        """)

        terminalScripts = [
            MobileDemoTerminalScript(
                surfaceID: "cmux-demo-term-review-agent",
                transcript: agentTranscript,
                workingDirectory: "/Users/demo/code/api-server",
                displayDirectory: "~/code/api-server",
                fileSystem: apiServerTree
            ),
            MobileDemoTerminalScript(
                surfaceID: "cmux-demo-term-review-tests",
                transcript: testsTranscript,
                workingDirectory: "/Users/demo/code/api-server",
                displayDirectory: "~/code/api-server",
                fileSystem: apiServerTree
            ),
            MobileDemoTerminalScript(
                surfaceID: "cmux-demo-term-release-build",
                transcript: buildTranscript,
                workingDirectory: "/Users/demo/code/mobile-app",
                displayDirectory: "~/code/mobile-app",
                fileSystem: mobileAppTree
            ),
            MobileDemoTerminalScript(
                surfaceID: "cmux-demo-term-release-shell",
                transcript: shellTranscript,
                workingDirectory: "/Users/demo/code/mobile-app",
                displayDirectory: "~/code/mobile-app",
                fileSystem: mobileAppTree
            ),
            MobileDemoTerminalScript(
                surfaceID: "cmux-demo-term-docs-dev",
                transcript: docsTranscript,
                workingDirectory: "/Users/demo/code/docs",
                displayDirectory: "~/code/docs",
                fileSystem: docsTree
            ),
        ]
    }
}
