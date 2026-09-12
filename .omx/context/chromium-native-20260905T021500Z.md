# Chromium native browser Ralph context

Task statement: Replace the unreliable cmux Chromium pane implementation with the strongest native architecture, preserving real Chromium behavior and Chrome extension support.
Desired outcome: A smooth, reliable browser experience in cmux with real Chromium semantics and MV3 extensions, verified in a tagged app.
Known facts/evidence:
- Screenshot-stream chrome-headless-shell path froze, distorted frames, and showed stale CDP errors.
- In-process CEF implementation exists in repository history commit 4b3951ccb4 and was restored on this branch.
- CEF framework/helpers embed successfully and real CEF panes launch with native Chromium helper processes.
- MV3 content scripts/background worker and persistent extension storage were verified in live CEF dogfood.
- CEF child-window adoption still produces an undesirable rounded/oversized browser surface in user screenshots.
- CEF Alloy runtime-style experiment caused Chromium startup failure and was reverted.
- Current branch includes native CEF commits 9351266604, 4bddd6b112, ed1217256c, 3141fe7861.
- Current working tree has only an unrelated vendor/bonsplit submodule modification.
Constraints:
- Preserve current branch/workspace. Do not touch vendor/bonsplit change.
- Use tagged builds only. Verify real runtime and MV3 extension behavior.
- No fake availability flags or blank-pane scaffolds.
- Keep lifecycle asynchronous and bounded; no UI freezes.
- Do not push or merge without explicit later approval.
Unknowns/open questions:
- Whether direct CEF BrowserView embedding can remove the child-window chrome without breaking CEF.
- Whether native WKWebView + WKWebExtension is acceptable if full Chromium window embedding is impossible.
- Whether normal external Chrome windows can satisfy cmux pane semantics.
Likely touchpoints:
- Sources/Panels/CEFBrowserHostView.swift
- Sources/Panels/CEFBrowserPaneEngineAdapter.swift
- Packages/macOS/CmuxCEF/Sources/CmuxCEFShim/cmux_cef_shim.m
- Packages/macOS/CmuxCEF/Sources/CmuxCEF/CEFBrowser.swift
- Packages/macOS/CmuxCEF/Sources/CmuxCEF/CEFRuntime.swift
- Scripts ensure-cef.sh/embed-cef.sh/reload.sh
- BrowserPanel engine adapters and CEF/MV3 tests
