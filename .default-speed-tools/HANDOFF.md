# Default-grid detector handoff — not ready to publish

Worktree: /mnt/lane-data/checkouts/cmux/lane--phone-default-speed
HEAD: 0bf277ae887951f3bb975e6ec3eaef712366f9e9 (parent integration only; detector uncommitted)

Native build timed out at 600s and 1800s. No baseline.tsv, check.log fixture, native unit results, measured cost, mutation results, or device calibration exists. Do not land staged provisional standalone CI routing. Owned standalone target and Zig install were removed; source/logs and shared caches preserved.

Existing native compilation: .github/workflows/cmux-tui-artifacts.yml job cmux-next-daemon-tests, save step lines 2404–2415; ci/steps.toml cmux-next-daemon-tests consumer uses scripts/ci/cmux-tui-test-target.sh. Cache key cmux-next-daemon-tests-cargo-v1-<environment>-<4-hour window>, absolute checkout path included; 420s restore bound and 30GiB free floor. No exact matching artifact was verified. Profile/features/native CPU differ from standalone release/baseline detector.

Integration prerequisite: move detector into ghostty-vt as a workspace example, sharing an existing PR compilation's target/profile/features/toolchain/CPU settings from job start. Existing .github/workflows/cmux-next-terminal.yml rust-terminal-linux compiles the core but only on push/dispatch, so it alone is not the PR gate. Configure Valgrind and route relevant PRs through shared compilation. Require Fresh ghostty-vt-sys on detector invocation, record wall/total CPU, generate real baseline/fixture, and run mutation checks before publication. Source-only routing and lock tests passed; their receipts are not native validation. Hardware-speed row11 stays incomplete pending fixed device calibration.
