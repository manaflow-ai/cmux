SHAs: a3c024b97615 (red test), 009a9feca3e4 (green fix), 5c48ff32e198 (worker-test cleanup), landed at 1aa78ee17b4a; 1aa78ee17b4a is an ancestor of origin/feat-cmux-next.
Gates: `bun install --frozen-lockfile`, `bun run check`, 18 focused tests, 213 changes/conversation tests, and all four committed web-bundle checks passed; the independent review found no production defects.
Bench: the plan records before = 1.05–1.15 s first TS/TSX highlight and 255 ms Swift; cmux-lawrence-2 was unreachable (DNS/Tailscale auth), so the required after first-paint measurement is UNVERIFIED.
Gallery URLs: none; this webview change has no gallery capture, and browser runners were not used.
Open issues: run `pane-bench.ts` on cmux-lawrence-2 when access returns; repository-wide verify-local still reports unrelated localization/package-group drift.
