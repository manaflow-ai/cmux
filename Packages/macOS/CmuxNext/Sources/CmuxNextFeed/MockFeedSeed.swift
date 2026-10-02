import Foundation

/// A believable feed: agents waiting on the user, browser requests, CI and
/// terminal notices, and a few closed requests. Poster text (titles,
/// prompts, labels) is content, not chrome, so it is not localized.
nonisolated enum MockFeedSeed {
    static func items(now: Date) -> [FeedItem] {
        func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
        let claude = { (label: String) in FeedPoster(kind: .agent, label: label, harness: "Claude Code", host: "MacBook Pro") }
        let codex = { (label: String) in FeedPoster(kind: .agent, label: label, harness: "Codex", host: "mini-3") }
        return requests(ago: ago, claude: claude, codex: codex) + notices(ago: ago) + closed(ago: ago, claude: claude, codex: codex)
    }

    private static func requests(ago: (TimeInterval) -> Date, claude: (String) -> FeedPoster, codex: (String) -> FeedPoster) -> [FeedItem] {
        [
            FeedItem(
                id: "fi_claude_rm_build", title: "Run rm -rf build && npm run build?",
                prompt: .approve(.init(
                    action: .init(type: .command, summary: "Clean and rebuild", command: "rm -rf build && npm run build",
                                  cwd: "~/src/api-server", tool: "Bash", risk: "deletes build/"),
                    scopes: [.once, .session, .always])),
                thread: "claude:api-server", context: FeedContext(workspace: "api-server", terminal: "term_7k2"),
                poster: claude("api-server"), createdAt: ago(40)),
            FeedItem(
                id: "fi_codex_edit", title: "Edit Sources/Feed/FeedModel.swift",
                prompt: .approve(.init(
                    action: .init(type: .edit, summary: "Apply patch to 1 file", tool: "apply_patch", diff: "att_diff"),
                    scopes: [.once, .session])),
                thread: "codex:cmux-next", context: FeedContext(workspace: "cmux-next", terminal: "term_q81"),
                attachments: [FeedAttachment(id: "att_diff", name: "FeedModel.swift.diff", mime: "text/x-diff", size: 612, text: diff)],
                poster: codex("cmux-next"), createdAt: ago(190)),
            FeedItem(
                id: "fi_claude_choice", title: "Two questions about the login flow",
                prompt: .choice(.init(questions: [
                    .init(id: "q_auth", question: "Which sign-in method should the CLI use?", header: "Sign-in", options: [
                        .init(id: "device", label: "Device code", detail: "Works over SSH"),
                        .init(id: "browser", label: "Browser redirect", detail: "Fewer steps on a desktop"),
                        .init(id: "token", label: "Paste a token"),
                    ]),
                    .init(id: "q_scope", question: "Which commands need sign-in?", header: "Scope", options: [
                        .init(id: "push", label: "push"),
                        .init(id: "deploy", label: "deploy"),
                        .init(id: "logs", label: "logs"),
                    ], multi: true, allowOther: true),
                ])),
                thread: "claude:api-server", context: FeedContext(workspace: "api-server", terminal: "term_7k2"),
                poster: claude("api-server"), createdAt: ago(360)),
            FeedItem(
                id: "fi_codex_question", title: "Name for the release branch?",
                prompt: .question(.init(question: "What should the release branch be called?", suggestions: ["release/0.80", "rc/0.80.0"])),
                context: FeedContext(workspace: "docs-site"), poster: codex("docs-site"), createdAt: ago(540)),
            FeedItem(
                id: "fi_passkey_github", title: "Passkey for github.com",
                prompt: .passkey(.init(origin: "https://github.com", rpID: "github.com", ceremony: .get, browserTab: "btab_gh",
                                       reason: "Confirm access to repository settings")),
                context: FeedContext(workspace: "infra", browserTab: "btab_gh", url: URL(string: "https://github.com/settings")),
                poster: claude("infra"), createdAt: ago(720)),
            FeedItem(
                id: "fi_signin_dashboard", title: "Sign in to dashboard.stripe.com",
                prompt: .signIn(.init(origin: "https://dashboard.stripe.com", url: URL(string: "https://dashboard.stripe.com/login"),
                                      browserTab: "btab_billing", reason: "Read the failed payouts report")),
                context: FeedContext(workspace: "billing", browserTab: "btab_billing"),
                poster: codex("billing"), createdAt: ago(900)),
            FeedItem(
                id: "fi_claude_plan", title: "Review the plan: split FeedModel",
                body: "1. Move grouping into a pure type.\n2. Keep the intent log in the model.\n3. Add tests for late answers.",
                prompt: .review(.init(subject: .plan, ref: "plan_7", checklist: ["Grouping is pure", "Intent log unchanged"])),
                thread: "claude:cmux-next", context: FeedContext(workspace: "cmux-next", terminal: "term_m4a"),
                poster: claude("cmux-next"), createdAt: ago(1_500)),
            FeedItem(
                id: "fi_codex_handoff", title: "Please take over: migration 0042 fails",
                body: "The migration fails on the staging copy with a lock timeout. I stopped before retrying.",
                prompt: .handoff(.init(reason: "Lock timeout on staging", resumeHint: "Run it again after the backfill finishes")),
                context: FeedContext(host: "mini-3", workspace: "infra", terminal: "term_z90"),
                poster: codex("infra"), createdAt: ago(2_400)),
        ]
    }

    private static func notices(ago: (TimeInterval) -> Date) -> [FeedItem] {
        [
            FeedItem(
                id: "fi_status_run", title: "cargo test finished in 42 s", body: "412 passed, 0 failed",
                context: FeedContext(workspace: "cmux-tui", terminal: "term_c11"),
                poster: FeedPoster(kind: .system, label: "status run"), createdAt: ago(95)),
            FeedItem(
                id: "fi_build_done", title: "Build 1842 passed", body: "feat-cmux-next · 6 min 12 s",
                thread: "ci:cmux", poster: FeedPoster(kind: .server, label: "ci-runner"), readAt: ago(400), createdAt: ago(480)),
            FeedItem(
                id: "fi_github_review", title: "Review requested: manaflow-ai/cmux#16201",
                body: "Feed: mirror and intent log", context: FeedContext(url: URL(string: "https://github.com/manaflow-ai/cmux/pull/16201")),
                poster: FeedPoster(kind: .integration, label: "GitHub"), createdAt: ago(1_900)),
            FeedItem(
                id: "fi_osc9", home: .local(install: "inst_mbp"), title: "Render complete", body: "out/demo.mp4 (1080p, 38 s)",
                dedupeKey: "osc:term_f3:9a1", context: FeedContext(workspace: "video", terminal: "term_f3"),
                poster: FeedPoster(kind: .system, label: "ffmpeg"), readAt: ago(3_000), createdAt: ago(3_400)),
            FeedItem(
                id: "fi_build_prev", title: "Build 1841 failed", body: "check-l10n: 3 missing keys",
                thread: "ci:cmux", poster: FeedPoster(kind: .server, label: "ci-runner"), readAt: ago(80_000), createdAt: ago(90_000)),
            FeedItem(
                id: "fi_build_old", title: "Build 1840 passed",
                thread: "ci:cmux", poster: FeedPoster(kind: .server, label: "ci-runner"), readAt: ago(95_000), createdAt: ago(96_000)),
        ]
    }

    private static func closed(ago: (TimeInterval) -> Date, claude: (String) -> FeedPoster, codex: (String) -> FeedPoster) -> [FeedItem] {
        [
            FeedItem(
                id: "fi_answered_push", title: "Run git push origin feat-login?",
                prompt: .approve(.init(action: .init(type: .command, summary: "Push the branch", command: "git push origin feat-login"))),
                poster: claude("api-server"), state: .answered,
                answer: FeedAnswerRecord(value: .approve(.init(.allow, scope: .once)), by: "usr_lawrence", device: "iPhone", at: ago(86_000)),
                readAt: ago(86_000), createdAt: ago(86_400), closedAt: ago(86_000)),
            FeedItem(
                id: "fi_expired_npm", title: "Allow network access to registry.npmjs.org?",
                prompt: .approve(.init(action: .init(type: .network, summary: "Fetch packages"))),
                poster: codex("docs-site"), state: .expired, readAt: nil, createdAt: ago(172_800), closedAt: ago(86_400)),
        ]
    }

    static let diff = """
    --- a/Sources/Feed/FeedModel.swift
    +++ b/Sources/Feed/FeedModel.swift
    @@ -41,9 +41,12 @@ public final class FeedModel {
         public var visibleItems: [FeedItem] {
             var items = confirmed
    -        for intent in pending {
    -            items = intent.applied(to: items)
    +        for intent in pending where !intent.isSettled {
    +            intent.apply(to: &items, user: user, device: device)
             }
    -        return Array(items.values)
    +        return items.values.sorted(by: FeedOrder.newest)
         }
    +
    +    /// An intent on this item still waits for the owner.
    +    public func isPending(_ id: String) -> Bool { pending.contains { $0.items?.contains(id) ?? true } }
    """
}
