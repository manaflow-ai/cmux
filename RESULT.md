Red SHA: 8b436fa1d408 (helper regression ran red); green SHA: be1bbf184323; merged origin/feat-cmux-next at 0adf6982430f.
Gates: `bun run check` and `bun test test/support/requireBrowserLane.test.ts` passed after merge; browser test files were not run.
Gallery URLs: none (gallery captures were not run locally; Freestyle-only execution remains configured with CMUX_BROWSER_TESTS=1).
Open issues: safe-push is unavailable in this checkout and available HQ/tool paths, so the requested landing push could not run.
Policy: no browser runner, Playwright browser, cargo, zig, xcodebuild, or Swift test was run on this laptop.
