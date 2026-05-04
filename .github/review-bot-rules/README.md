# cmux Review Bot Rules

These rules are the shared source of truth for Greptile and CodeRabbit custom Swift review behavior.

The rule files are intentionally short and focused. Each one defines one class of issue, concrete failure cases, allowed cases, and the expected reporting shape. Keep new rules narrow enough that a reviewer can apply the rule to a full PR diff without turning it into a broad style guide.

Greptile is configured to publish a GitHub status check. CodeRabbit is configured with error-mode custom pre-merge checks, which can block when the repository's CodeRabbit request-changes workflow is enabled.

Current rules:

- `swift-actor-isolation.md`
- `swift-architectural-rethink.md`
- `swift-blocking-runtime.md`
- `swift-concurrency-modernization.md`
- `swift-concurrent-annotation.md`
- `swift-logging.md`
- `swiftui-state-layout.md`

Open source repository note: review bots should apply the configuration from the base branch. A PR that edits these rules should not be able to weaken its own review.
