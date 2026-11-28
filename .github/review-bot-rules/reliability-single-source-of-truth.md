# Reliability and Single Source of Truth

Apply this rule to production code that detects, identifies, or tracks correctness-critical state: which coding agent is running, agent/session lifecycle and liveness, workspace/pane/surface identity, and any value the UI trusts to enable/disable controls, route input, or show a specific conversation.

The lesson is from agent detection in the mobile transcript service: detecting the running agent by parsing window/pane titles, and degrading to a "best effort" branch when the reliable signal was missing, could show the wrong conversation or none. The fix is one reliable source of truth, no unreliable fallback, and no read path that trades freshness for a fixed delay.

## Fail

- A correctness-critical value derived from a string/title/name heuristic: matching on a terminal title, window title, pane label, process argv substring, or display name to decide agent type, session identity, liveness, or which conversation to show.
- An "unreliable but better than nothing" fallback branch added next to the reliable path (a guess, a default, a `// best effort` branch) for state where showing the wrong value is a correctness bug, not a cosmetic one.
- More than one source of truth for the same correctness-critical fact (for example a cached title and a real session id that can disagree), without a single authority designated and the others reduced to derived/diagnostic.
- A throttle or polling interval placed on a correctness-critical state read that introduces a visible staleness window (for example reading agent state at most once every N seconds), where the consumer must reflect the change promptly.

## Pass

- Detection that uses a reliable, structured source of truth: an explicit session id, a registered agent descriptor, a typed lifecycle event, or another authoritative record, with no title/name heuristic in the decision.
- A missing reliable signal that fails closed (no detection, control disabled, empty state) rather than guessing, when guessing could mislead the user.
- A heuristic used only for a genuinely cosmetic, non-authoritative hint (an icon guess, a placeholder label) where being wrong has no correctness consequence and the code says so at the call site.
- Throttling/coalescing of expensive work that does not delay the observable correctness-critical value (for example debouncing redundant recomputation while the authoritative state is still read promptly).

## Report

When this rule fails, name the exact file and line, state which correctness-critical fact is being derived unreliably, and propose the single authoritative source it should read instead. If the diff adds a fallback, say whether the correct fix is to remove the fallback and fail closed.
