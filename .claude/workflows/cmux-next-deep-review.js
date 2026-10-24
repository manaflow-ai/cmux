export const meta = {
  name: 'cmux-next-deep-review',
  description: 'Deep review of landed ranges: six-lens reviewer panel (incl. completeness), three adversarial refuters per finding, principled fixes, two-lens review of each fix, fleet test, land; loop until dry',
  phases: [
    { title: 'Review', detail: 'six independent lenses per range' },
    { title: 'Verify', detail: 'three refuters per finding; keep if 2 of 3 confirm' },
    { title: 'Fix', detail: 'principled root-cause fixes, code only' },
    { title: 'Fix review', detail: 'correctness and no-hack lenses on the fix' },
    { title: 'Test', detail: 'fleet compile, tests, guard red/green' },
    { title: 'Land', detail: 'rebase, plain push' },
  ],
}
const UNITS = args
const BRIEF = `You review and fix landed work in the cmux repo (feat-cmux-next). FIRST read plans/cmux-next/REVIEW-STANDARD.md (correctness, root cause, rejected hacks, real guards, no partial fixes), plans/cmux-next/PATTERNS.md (the patterns every change must use) and plans/cmux-next/OWNERS.md (owned areas: send changes to their owner instead of editing). If /Users/lawrence/fun/wt/perf-lead-brief.md exists, read it too and follow its ownership rules. Use \`git show\`/\`git log origin/feat-cmux-next\` to read landed commits (fetch only feat-cmux-next). Build and test only on the fleet (cmux-ci, nx-remote), never on a laptop.`
const S = { type: 'array', items: { type: 'string' } }
const FIND = { type: 'object', properties: { findings: { type: 'array', items: { type: 'object', properties: {
  severity: { type: 'string', enum: ['critical', 'major', 'minor'] }, file: { type: 'string' }, line: { type: 'integer' },
  problem: { type: 'string' }, failure_scenario: { type: 'string' }, principled_fix: { type: 'string' } },
  required: ['severity', 'file', 'problem', 'failure_scenario', 'principled_fix'] } } }, required: ['findings'] }
const VERDICT = { type: 'object', properties: { refuted: { type: 'boolean' }, reason: { type: 'string' } }, required: ['refuted', 'reason'] }
const APPLY = { type: 'object', properties: { commits: S, fixed: S, routed_to_cmux_b6: S, not_fixed: S, test_plan: { type: 'string' } }, required: ['commits', 'fixed', 'routed_to_cmux_b6', 'not_fixed', 'test_plan'] }
const TEST = { type: 'object', properties: { ok: { type: 'boolean' }, failures: S, summary: { type: 'string' } }, required: ['ok', 'failures', 'summary'] }
const LAND = { type: 'object', properties: { landed: { type: 'boolean' }, sha_range: { type: 'string' }, reason: { type: 'string' } }, required: ['landed', 'sha_range', 'reason'] }

const LENSES = [
  ['correctness', 'Correctness: trace each changed path end to end; races, reentrancy, lifetimes, leaks, error/cancel paths, every entrypoint sharing one path, both web engines.'],
  ['principled', 'Root cause and hacks: does each change remove the real cause, or move or hide it? Look for every hack pattern in the brief\'s REVIEW AND FIX STANDARD (sleeps, polling, retries, throttles, widened thresholds, swallowed errors, silent defaults, flags hiding bugs, magic numbers, skip env vars, duplicated paths, renames that dodge counts).'],
  ['concurrency', 'Concurrency and architecture: CLAUDE.md Swift 6 rules (actors, no locks except the carve-out, no DispatchQueue.main.async, no assumeIsolated without a seam reason), injection at the composition root, no layer violations, no new singletons; for Rust: lock order, fd ownership, signal safety.'],
  ['guards', 'Tests and guards: does each regression guard fail on the real buggy code and pass on the fix, through runtime behavior (not source text)? Is any test special-cased, loosened, or only testing an intermediate version? Are tests wired (pbxproj) so they actually run?'],
  ['completeness', 'Completeness and laziness: is the change the whole correct fix, or a smaller piece that looks done? Find deferrals ("follow-up", "later", "out of scope", "left as is"), exceptions kept without a reason that holds, shortcuts the author lists in its own commit messages or plan rows, work that only covers one entrypoint, one engine or one macOS major, a pattern from PATTERNS.md not used where it applies, and counts lowered by renames. Each one is a finding with the complete fix.'],
  ['platform', 'Platform and product: macOS 14/15/26/27 API differences, localization (en+ja) of every new string, accessibility, perf on hot paths (perf-hot markers; any new per-frame or per-key work), shipped vs debug builds.'],
]

async function unit(u) {
  const wt = `/Users/lawrence/fun/wt/deep-${u.name}`
  const panel = await parallel(LENSES.map(([k, d]) => () => agent(`${BRIEF}\nMODE: read only; do not edit, build or run.\nYou are the ${k} reviewer of "${u.name}". Landed commits: ${u.ranges.join(', ')}. Context: ${u.summary}\n${d}\nReview only the changes in these commits (git show each). For each real problem give file, line, a concrete failure scenario and the principled fix. Do not report style nits. Return an empty list if you find nothing real.`, { label: `${k}:${u.name}`, phase: 'Review', schema: FIND })))
  const seen = new Set(); const all = []
  for (const p of panel.filter(Boolean)) for (const f of p.findings) { const key = `${f.file}:${f.line || 0}:${f.problem.slice(0, 60)}`; if (!seen.has(key)) { seen.add(key); all.push(f) } }
  if (!all.length) return { name: u.name, confirmed: [], note: 'no findings' }
  const checked = await parallel(all.map(f => () => parallel([0, 1, 2].map(i => () => agent(`${BRIEF}\nMODE: read only.\nRefuter #${i + 1}. Try to REFUTE this review finding about "${u.name}" (commits ${u.ranges.join(', ')}): ${JSON.stringify(f)}\nRead the actual code at the landed tip (git show origin/feat-cmux-next:FILE) and the commits. Refute it if the code does not do what the finding claims, if the scenario cannot happen, or if it is already fixed on the tip. If you cannot refute it with evidence, set refuted=false.`, { label: `verify${i + 1}:${u.name}`, phase: 'Verify', schema: VERDICT }))).then(vs => ({ f, confirms: vs.filter(Boolean).filter(v => !v.refuted).length }))))
  const confirmed = checked.filter(Boolean).filter(c => c.confirms >= 2).map(c => c.f)
  log(`${u.name}: ${all.length} findings, ${confirmed.length} confirmed by at least 2 of 3 refuters`)
  if (!confirmed.length) return { name: u.name, confirmed: [] }
  const nr = `MODE: code only (no builds or fleet jobs). Worktree ${wt} (create once: cd ~/fun/cmux && git fetch origin feat-cmux-next && git worktree add -B deep-${u.name} ${wt} FETCH_HEAD; else rebase it on origin/feat-cmux-next). Commit locally; do not push.`
  let fix = await agent(`${BRIEF}\n${nr}\nFix these confirmed findings for "${u.name}" with principled root-cause fixes, each with a regression guard that fails without it (red commit first): ${JSON.stringify(confirmed).slice(0, 12000)}\nFor a finding in a file owned by a cmux-b6 agent (brief OWNERSHIP SPLIT / ARCHITECTURE WORK), do not edit: send it to session \`cmux-b6 [0ad95f]\` as one self-contained message with the principled fix, and list it in routed_to_cmux_b6.`, { label: `fix:${u.name}`, phase: 'Fix', schema: APPLY })
  if (!fix || !fix.commits.length) return { name: u.name, confirmed, fix }
  for (let round = 1; round <= 2; round++) {
    const fr = await parallel(['correctness', 'principled'].map(k => () => agent(`${BRIEF}\nMODE: read only.\nReview the fix commits in ${wt} (git log origin/feat-cmux-next..HEAD -p) for "${u.name}" with the ${k} lens. ${LENSES.find(l => l[0] === k)[1]} Also: does each guard fail without its fix?`, { label: `fixreview-${k}${round}:${u.name}`, phase: 'Fix review', schema: FIND })))
    const fs = fr.filter(Boolean).flatMap(r => r.findings)
    if (!fs.length) break
    fix = await agent(`${BRIEF}\n${nr}\nApply the fix-review findings for "${u.name}" (principled fixes only): ${JSON.stringify(fs).slice(0, 10000)}`, { label: `fixapply${round}:${u.name}`, phase: 'Fix review', schema: APPLY }) || fix
  }
  let t = await agent(`${BRIEF}\nMODE: testing in ${wt}; no product edits. Plan: ${(fix.test_plan || '').slice(0, 3000)}\nOn the fleet: cmux-ci compile-check --app (and the Rust check scripts/ci/cmux-tui-rust-check.sh for cmux-tui changes); the affected test suites on macOS 27 and one other major; each guard red on origin/feat-cmux-next and green on the branch.`, { label: `test:${u.name}`, phase: 'Test', schema: TEST })
  if (t && !t.ok) {
    await agent(`${BRIEF}\n${nr}\nFix these test failures for "${u.name}" at their root cause: ${JSON.stringify(t).slice(0, 8000)}`, { label: `testfix:${u.name}`, phase: 'Test', schema: APPLY })
    t = await agent(`${BRIEF}\nMODE: testing in ${wt}; re-run the same plan after the fix.`, { label: `retest:${u.name}`, phase: 'Test', schema: TEST })
  }
  const l = t && t.ok ? await agent(`${BRIEF}\nMODE: landing in ${wt}: fetch only feat-cmux-next, rebase (keep others' work), compile-check again if Swift files you touch changed meanwhile, plain push, verify with gh api compare.`, { label: `land:${u.name}`, phase: 'Land', schema: LAND }) : { landed: false, sha_range: '', reason: 'tests not green' }
  return { name: u.name, confirmed: confirmed.length, routed: fix.routed_to_cmux_b6, not_fixed: fix.not_fixed, land: l }
}
return await pipeline(UNITS, u => unit(u))
