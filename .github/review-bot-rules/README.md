# cmux Review Bot Rules

These rules are the shared source of truth for Greptile and CodeRabbit custom review behavior.

The rule files are intentionally short and focused. Each one defines one class of issue, concrete failure cases, allowed cases, and the expected reporting shape. Keep new rules narrow enough that a reviewer can apply the rule to a full PR diff without turning it into a broad style guide.

Greptile is configured to publish a GitHub status check and inline findings. CodeRabbit is configured with assertive review, request-changes workflow, and error-mode custom pre-merge checks so unresolved findings can block merge through CodeRabbit's review flow.

Current rules:

- `algorithmic-complexity.md`
- `browser-automation-webkit-waits-off-main.md`
- `cache-substitution-correctness.md`
- `full-internationalization.md`
- `hot-path-allocating-formatting.md`
- `no-ambient-global-state.md`
- `no-test-debug-seam-in-production-source.md`
- `react-base-ui-accessibility.md`
- `reliability-single-source-of-truth.md`
- `runtime-no-hacky-sleeps.md`
- `source-control-artifacts.md`
- `swiftpm-package-resolved.md`
- `swift-actor-isolation.md`
- `swift-architectural-rethink.md`
- `swift-auxiliary-window-close-shortcuts.md`
- `swift-blocking-runtime.md`
- `swift-concurrency-modernization.md`
- `swift-concurrent-annotation.md`
- `swift-expensive-sync-load.md`
- `swift-file-package-boundaries.md`
- `swift-logging.md`
- `swiftui-state-layout.md`
- `user-facing-errors.md`
- `readme-site-feature-parity.md`
- `landing-page-registry-parity.md`

Open source repository note: review bots should apply the configuration from the base branch. A PR that edits these rules should not be able to weaken its own review.
