# Instant lists: the iOS perf bench

Leo, 2026-11-10: "to load in my God sessions, it needs to be the exact same, or I
mean, close enough to the exact same as the small sessions. ... We need to be
dealing with realistic, degenerate events and be holding ourselves up to that bar."

Every metric here is measured twice, on a SMALL and a GOD fixture, and judged on
two rules. The design for making them pass (caches, bounded catch-up, row
parsing) is `plans/feat-ios-instant-list/DESIGN.md` in manaflow-ai/cmuxterm-hq.

## The rules

- **Budget**: small and god each at most 3x the target. The target is the goal;
  3x keeps shared CI runners from flaking.
- **Ratio (1.2x)**: god at most 1.2x small, computed as
  `god / max(small, 1 ms)`. Below 1 ms nobody sees a difference, and a
  sub-millisecond small would make any ratio noise; the floor keeps "god costs
  what small costs" meaningful.
- **Known-red**: where today's code fails a rule, that check is declared in the
  test's `knownRed` with the reason, and runs under Swift Testing's
  `withKnownIssue`. The baseline records the red honestly. When a fix makes the
  check pass, the test fails until the declaration is removed. Never raise a
  target or drop a check to make a run pass.
- **Noise**: a god within 2 ms of small, or within a tenth of the metric's
  target if that is more (15 ms for a 150 ms target), passes the ratio whatever
  the quotient: a hosted simulator moved a 7 ms chat open by 5 to 30 ms between
  runs of one job. The budget check still holds both cases to 3x the target, so
  the allowance never hides a god that left the target. A known-red mark must come
  off only once its check passes at 75% of its limit; a check that only just
  passes on a quick runner stays marked and never fails the run.

## Metrics

Kit level (`cmux-next-ios/CmuxMobileKit/Tests/CmuxMobileInstantPerfTests`, measured
on every PR that touches `cmux-next-ios/**`):

| Metric | What is timed | Small | God | Target |
|---|---|---|---|---|
| `home_list_first_screen` | the first window's `home-inbox` reply bytes (20 rows and the list's `total`, as cmux-mobile-host cuts it) to the list the first screen draws (`MacHomeReply`, `MacHomeList`); the note has the whole list that follows off the main actor | 20 rows | 5,000 rows | 16 ms |
| `home_list_one_row_update` | one row changes in place in a list of N: what the feed does, the `ids` read's reply (that row and its index) parsed, put in place (`MacHomeRows.apply`) and the list patched (`MacHomeList.Memo`); the note has the memo alone | 20 rows | 5,000 rows | 4 ms |
| `chat_open_last_messages` | `AgentChatStore` on a fake acpmux, until it holds the newest turn, finished | ~40 records | 50,000 records | 150 ms |
| `chat_reconnect_catch_up` | link back (`bind`), reattach, until the newest turn shows (tail-first since slice 3: the gap before the newest page fills after, untimed; its time is in the note) | 10 missed | 20,000 missed | 150 ms |
| `chat_older_page` | one scroll-up page of older history (`loadEarlier`) | 450-record chat | 50,000 records | 50 ms |

Home reads windows (since the windowed Home read): the first screen asks cmux-mobile-host for
`limit: 20` rows of the scoped list (`chief_policy.rs`, `InboxWindow`), the whole list follows in
one read parsed off the main actor, and an event reads only its conversation's row (`ids`, with
its `index` and the list's `total`). The rows this phone last read show before any of it
(`MacHomeRowsCache`: the first 200 rows per account and Mac, 2 MB in all, deleted at sign-out).
A host without windows refuses the params and the phone reads the whole list, as before.

The god fixtures are degenerate on purpose: Home rows with pins, ~80 Chiefs
working, one preview in ten a long Markdown reply, six months of dates; the chat
has tool outputs up to 2 MB (logs and diffs), subagents nested 5 deep, 200 image
parts and six months of timestamps. Its last 2 MB log sits about 60 records
before the end: the open (capped at 128 KiB of whole records) stops short of it,
so `chat_open_last_messages` shows the cap holding, and the first scroll-up page
(`chat_older_page`) is the one that reads it.
`chat_reconnect_catch_up` still times from the link coming back to the newest turn shown.
What changed with the tail-first reattach (slice 3) is the work inside that window: a gap
longer than one page reads the newest page (as an open does) and one read after it, and the
missed records before that page are read afterwards, in 256 KiB pages, while the chat is
already showing its newest turn. That fill is not in the timed window; the bench runs it once
more on god to the end, checks every turn is then shown once and in order, and reports how
long it took in the note.

Fixtures are seeded generators (`InstantPerfFixtures.swift`), built in memory;
nothing large is checked in. The fake acpmux pages as acpmux does (`limit`,
`maxBytes` of whole records, `beforeSeq` / `afterSeq`: the newest records between them, or
oldest first after `afterSeq` alone) with index arithmetic, so
its own cost does not grow with the log.

UI level (`cmux-next-ios/UITests/InstantListPerfUITests.swift`, wired; runs on
owned simulators):

| Metric | How | Target |
|---|---|---|
| cold launch to first Home row | `XCTApplicationLaunchMetric`, `XCTClockMetric` to `home.row.stress-4` | 300 ms |
| warm launch to first Home row | `XCTApplicationLaunchMetric(waitUntilResponsive:)`, `XCTClockMetric` | 100 ms |
| Home scroll, 20 vs 5,000 rows | `XCTOSSignpostMetric.scrollingAndDecelerationMetric`, `XCTCPUMetric` | no hitches |
| reconnect after a network change | skipped: needs a DEBUG link-drop hook | 150 ms |
| fold or unfold (iPhone Duo): selection and scroll kept, no reload | skipped: no two-column layout yet (`testFoldTransitionKeepsSelectionAndScroll`) | one frame, 0 reloads, 0 pt |

## Running it

Locally (a Mac you may build on; never huge-blue, big-red, air-blue or cosmic-gray):

    swift test --package-path cmux-next-ios/CmuxMobileKit --filter CmuxMobileInstantPerfTests
    CMUX_INSTANT_PERF_OUT=/tmp/instant-perf.jsonl CMUX_INSTANT_PERF_RUNS=9 swift test ...   # JSONL, more runs
    python3 cmux-next-ios/scripts/instant_perf_table.py /tmp     # the table

Each metric prints `INSTANTPERF {json}`: metric, platform, small_ms, god_ms,
ratio, target_ms, budget_ms, the runs, the known-red and failing checks, a note.
Run it alone: other suites on the same cores move the numbers. Numbers are from
the Debug build the kit's tests use.

On the simulator: `xcodebuild test -scheme CmuxMobileKit-Package -only-testing:CmuxMobileInstantPerfTests`
with `TEST_RUNNER_CMUX_INSTANT_PERF_OUT=...` (xcodebuild strips the prefix for the test process).
UI half: `scripts/ci/cmux-next-ios-sim.sh test ui=InstantListPerfUITests`.

In CI, `.github/workflows/cmux-next-ios-kit.yml` skips the bench in the main
`swift test` and `xcodebuild test` runs, then runs it alone on macOS and on the iOS
simulator, prints the table to the job log and the job summary, and uploads the
JSONL as the `instant-perf-*` artifact.

## Adding a metric

1. Add a generator (or a size) to `InstantPerfFixtures.swift`: seeded, SMALL and GOD, lazy.
2. Add a `@Test("snake_case_metric")` to `InstantPerfTests.swift`: time only the work
   (setup outside the clock), with `InstantPerfReport.sample` for both sizes.
3. Call `InstantPerfReport.record(metric, target:, small:, god:)`. If today's code fails
   a check, declare it in `knownRed` with a `why` that names the cause.
4. Add the row to the tables above and to the design doc's metric list.
