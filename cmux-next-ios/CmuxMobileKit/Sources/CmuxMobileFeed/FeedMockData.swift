// DEBUG and Demo builds only: mock content is never compiled into Production.
#if DEBUG
import CmuxAgentQuestion
import CmuxMobileAgentChat
import Foundation

extension FeedStore {
    static func claude(_ id: String, _ kind: FeedItem.Kind, _ markdown: String, quote: FeedItem.Quote?, ago: TimeInterval, now: Date) -> FeedItem {
        FeedItem(id: id, kind: kind, workspaceID: "ws-cmux", tabID: "t-claude", agentName: "Claude", harness: "claude",
                 workspaceTitle: "cmux", markdown: markdown, quote: quote, createdAt: now.addingTimeInterval(-ago))
    }

    static func codex(_ id: String, _ kind: FeedItem.Kind, _ markdown: String, quote: FeedItem.Quote?, ago: TimeInterval, now: Date) -> FeedItem {
        FeedItem(id: id, kind: kind, workspaceID: "ws-web", tabID: "t-codex", agentName: "Codex", harness: "codex",
                 workspaceTitle: "cmux.com", markdown: markdown, quote: quote, createdAt: now.addingTimeInterval(-ago))
    }

    public static func mockItems(now: Date) -> [FeedItem] {
        let question = AgentQuestion(
            id: "feed-q-release",
            source: AgentQuestion.Source(harness: .claude, session: "t-claude", permission: "perm-feed-q", agentName: "Claude"),
            items: [
                AgentQuestion.Item(id: "channel", header: "Release", prompt: "Which channel should this build go to first?", options: [
                    AgentQuestion.Option(id: "nightly", label: "Nightly", detail: "Everyone on nightly gets it tonight."),
                    AgentQuestion.Option(id: "rc", label: "Release candidate", detail: "Cut rc2 and ask the team to dogfood."),
                    AgentQuestion.Option(id: "testflight", label: "TestFlight only"),
                ]),
                AgentQuestion.Item(id: "notes", header: "Changelog", prompt: "Which items belong in the changelog?", options: [
                    AgentQuestion.Option(id: "transport", label: "Switchable transport"),
                    AgentQuestion.Option(id: "feed", label: "Feed inline answers"),
                    AgentQuestion.Option(id: "diff", label: "Diff viewer"),
                ], multiSelect: true),
                AgentQuestion.Item(id: "notify", header: "Notify", prompt: "Post the release note to the team channel?", options: [
                    AgentQuestion.Option(id: "yes", label: "Yes, post it"),
                    AgentQuestion.Option(id: "no", label: "No, I'll post it"),
                ], allowsOther: false),
            ]
        )
        let permission = ACPPermissionRequest(
            id: "feed-perm-deploy",
            toolCall: ACPToolCall(id: "feed-x-deploy", title: "wrangler deploy", kind: .execute, status: .pending,
                                  rawInput: .object(["command": .string("bunx wrangler deploy --env staging")])),
            options: [
                ACPPermissionOption(id: "allow", name: "Allow once", kind: .allowOnce),
                ACPPermissionOption(id: "always", name: "Always allow", kind: .allowAlways),
                ACPPermissionOption(id: "deny", name: "Deny", kind: .rejectOnce),
            ],
            cwd: "~/Development/web"
        )
        return [
            claude("f-question", .question(question), """
            The release branch is green: **412 tests pass** and the dogfood build is signed. Before I tag it I need three decisions.
            """, quote: .init("Cut a release once CI is green on feat-cmux-next-ios"), ago: 50, now: now),
            codex("f-pricing", .response, """
            Fixed the pricing table overflow on small screens. The grid now wraps instead of forcing three columns:

            ```diff
            - grid-template-columns: repeat(3, 1fr);
            + grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
            ```

            | Device | Before | After |
            | --- | --- | --- |
            | iPhone SE | clipped | 1 column |
            | iPhone 17 Pro | clipped | 1 column |
            | iPad mini | 3 columns | 2 columns |

            I also checked dark mode and the annual toggle; both render correctly. All **14** tests pass and Lighthouse stays at 98.
            """, quote: .init("the pricing page breaks on iPhone SE"), ago: 240, now: now),
            codex("f-permission", .permission(permission), """
            I'm ready to deploy the pricing fix to **staging**. This publishes the Worker and purges the cache for `/pricing`.
            """, quote: .init("ship it to staging when the tests pass"), ago: 420, now: now),
            claude("f-math", .response, """
            The reconnect backoff now follows a capped exponential with jitter:

            $$
            d_n = \\min\\left(d_{\\max},\\; d_0 \\cdot 2^{n}\\right) \\cdot (1 + \\epsilon), \\quad \\epsilon \\sim \\mathcal{U}(-0.2, 0.2)
            $$

            With $d_0 = 250\\,\\text{ms}$ and $d_{\\max} = 8\\,\\text{s}$ the fifth retry waits about $4\\,\\text{s}$. The expected total before giving up is

            $$
            \\mathbb{E}[T] = \\sum_{n=0}^{N-1} \\min(d_{\\max}, d_0 2^n) \\approx 23.75\\,\\text{s}
            $$

            I added `BackoffTests` covering the cap and the jitter bounds.
            """, quote: .init("why does reconnect hammer the relay after sleep?"), ago: 900, now: now),
            claude("f-finished", .finished, """
            **Finished:** extracted `LinkDialer` into `CmuxMobileTransport` and added WireGuard dialing behind `TransportKind`.

            - 3 files changed, +118 −24
            - Swift and Rust link tests pass
            - Settings → Connection now switches transport live
            """, quote: .init("Make the transport layer switchable between WebRTC and WireGuard"), ago: 1600, now: now),
            codex("f-failed", .failed, """
            The e2e job failed on `checkout.spec.ts`: the Stripe test card form never finished loading.

            ```text
            TimeoutError: locator('iframe[name^=__privateStripeFrame]') exceeded 30000ms
            ```

            This looks like the sandbox outage from this morning, not our change. Want me to retry?
            """, quote: .init("run the e2e suite"), ago: 2400, now: now),
            claude("f-long", .response, """
            ## Feed rendering plan

            The Feed renders every event body in a pooled `WKWebView` so tables, code and math all work.

            1. **Pool.** Six web views are prewarmed with the template, so scripts parse once per view.
            2. **Measure.** Heights are measured in JavaScript off screen and cached per width.
            3. **Cap.** Bodies longer than eight lines show a fade and *Show more*.
            4. **Reuse.** A recycled view gets new content through one JavaScript call, never a page load.

            > Native `AttributedString` stays the fallback if scroll hitches exceed one frame.

            ```swift
            let height = WebMarkdownRenderer.shared.cachedHeight(markdown: body, style: .body, width: column)
            ```

            Measured on the iOS 26 simulator: first paint of a cell is under one frame once the pool is warm, and scrolling 40 events shows no dropped frames.
            """, quote: .init("how will the feed render markdown without jank?"), ago: 3600, now: now),
            codex("f-agent-quote", .response, """
            Done. I kept the old `/v1/pricing` route as a redirect so cached links still work.
            """, quote: .init("Should I keep the old route as a redirect?", author: .agent), ago: 5400, now: now),
        ]
    }

    static func liveSamples(now: Date) -> [FeedItem] {
        [
            claude("live-review", .finished, """
            **Review ready:** the diff viewer now supports split view, hunk expansion and viewed checkmarks. 5 files changed, +412 −37.
            """, quote: .init("build the diff viewer"), ago: 0, now: now),
            codex("live-lint", .response, "Lint is clean after the import fix. Pushing now.", quote: .init("fix lint"), ago: 0, now: now),
        ]
    }
}
#endif
