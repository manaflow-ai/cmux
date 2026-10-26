export const meta = {
  name: 'perf-sheriff',
  description: 'One perf-sheriff pass over the lab alert queue: take, confirm with a try job, read the bisect culprit, then flip its perfPath feature off or fix it from the stored traces with 2 adversarial reviewers and a verification try job. --dry-run prints one plan per group.',
  whenToUse: 'A rotating sheriff session (or the Performance Lead) works the MQ10 queue, `lab.py alerts --state new,triaged,culprit --json`. Pass "--dry-run" or {dryRun: true} to print the plans only; {only: [group ids]} limits the pass (the canary); {groups: [...]} plans a saved queue without reading the lab. A live pass needs {session: "<the calling sheriff session id>"} (or "--session ID"): every lab.py sheriff command of the pass runs as that session, so one claim holds for all its steps.',
  phases: [
    { title: 'Queue', detail: 'lab.py alerts --state new,triaged,culprit --json' },
    { title: 'Triage', detail: 'take the group, confirm it with a try job, read the bisect' },
    { title: 'Culprit', detail: 'strict re-verify an unverified culprit; perfPath check with --feature X=off' },
    { title: 'Flag off', detail: 'PR that flips the feature default, gen-features.py, risk label, take-back line, flag-off' },
    { title: 'Fix', detail: 'fixer agent from the stored traces (task 157)' },
    { title: 'Review', detail: '2 adversarial reviewers per REVIEW-STANDARD' },
    { title: 'Verify', detail: 'verification try job, PR, assigned; revert only through gh-merge-green --revert' },
  ],
}

// Chromium's perf sheriff rotation (docs/speed/perf_regression_sheriffing.md): triage each alert
// group, let Pinpoint bisect it, then turn the culprit's feature off first (Finch kill,
// components/variations) or get the culprit fixed or reverted. Design: section 3.7 of
// plans/cmux-next/chrome-parity/p12-perf-process.md. State changes go only through
// `lab.py sheriff` (task 019): `take` claims a group for this session (a 2 h lease, no state move), `set`
// moves it and needs --reason for assigned, flag-off and invalid. Try jobs only through `lab.py try` (task 018).

const LAB = 'python3 scripts/perf-lab/lab.py'
const TRACE = 'python3 scripts/cmux-next/trace.py'
const GEN = 'python3 scripts/cmux-next/gen-features.py'
const REVERT = 'scripts/gh-merge-green --revert manaflow-ai/cmux#N'
function revertCmd(pr) { return REVERT.replace('#N', '#' + (pr || 'N')) }
const QUEUE_STATES = 'new,triaged,culprit'
const ATTEMPTS = 20
const FIX_ATTEMPTS = 2
const REVIEW_ROUNDS = 2
// Section 3.7 SLOs from the alert time. sheriff.py (019) owns the SLO report; the plan only prints the deadlines.
const SLO_HOURS = { triage: 1, culprit: 4, fix: 12 }
// R3: an alert is never cleared by moving the bar. A fix that touches one of these files is refused.
const FORBIDDEN_FILE = /(budget|threshold|expectation|baseline|perf-hot-benches|subscriptions\.json|targets\.json|perf_stats|anomaly|pinpoint|shard_map|reference\.json)/i

const OPTS = parseOpts(args)
// sheriff.py names the actor from CMUX_AGENT_SESSION; every step's agent sets it to the calling sheriff session.
const SESSION_ID = /^[A-Za-z0-9][A-Za-z0-9._:@-]{0,127}$/

// ---- plan (pure: the dry run and the live pass print the same plan) ----

function parseOpts(a) {
  const o = { dryRun: false, only: null, groups: null, session: '' }
  if (a == null) return o
  if (typeof a === 'string' || Array.isArray(a)) {
    const words = Array.isArray(a) ? a.map(String) : a.split(/\s+/)
    o.dryRun = words.includes('--dry-run')
    const at = words.indexOf('--session')
    if (at >= 0) o.session = words[at + 1] || ''
    const ids = words.filter((w, i) => w && !w.startsWith('--') && !(at >= 0 && i === at + 1))
    if (ids.length) o.only = ids
    return o
  }
  o.dryRun = Boolean(a.dryRun || a['dry-run'])
  o.session = a.session ? String(a.session) : ''
  if (Array.isArray(a.only) && a.only.length) o.only = a.only.map(String)
  else if (a.only != null && !Array.isArray(a.only)) o.only = [String(a.only)]
  if (Array.isArray(a.groups)) o.groups = a.groups
  return o
}

function deadline(alertAt, hours) {
  const t = new Date(alertAt).getTime()
  return Number.isFinite(t) ? new Date(t + hours * 3600000).toISOString() : 'unknown (no alert_at)'
}

function baseBranch(g) { return g.base_branch || 'feat-cmux-next' }

function tryCmd(base, head, g, extra) {
  return `${LAB} try --base ${base} --head ${head} --stories ${g.story} --attempts ${ATTEMPTS}${extra ? ' ' + extra : ''} --wait`
}

function culpritSteps(g) {
  const c = g.culprit_sha || 'C'
  const steps = []
  if (g.culprit_verified !== 'verified') {
    steps.push(`re-verify the culprit (strict rule): ${tryCmd(c + '^', c, g)}; strict DIFFERENT in the regression direction goes on, anything else stays at culprit and goes to the Performance Lead`)
  }
  steps.push(`perfPath check: for each perfPath feature in schemas/features/features.d/ that ${c} adds, turns on or gates code in, ${tryCmd(c + '^', c, g, '--feature X=off')}; the head arm with X off not DIFFERENT from the base arm means the feature carries the regression`)
  steps.push(`if a feature carries it: PR on ${baseBranch(g)} that sets the feature's on defaults to false in schemas/features/features.d/X.json, ${GEN}, ${GEN} --check, commit the JSON and generated files, label risk:normal, body line "Takes back #${g.culprit_pr || 'N'}: <story>.<metric> regressed <delta> on <host class>, receipt <try receipt>", one review agent, ready-to-land, then ${LAB} sheriff set ${g.id} assigned --reason <PR url> and ${LAB} sheriff set ${g.id} flag-off --reason "X off by default in <PR url>"`)
  steps.push(`else: fixer agent from the stored traces of ${c}^ and ${c} (${TRACE} summary), never edits budgets, thresholds or expectations; ${REVIEW_ROUNDS} rounds of 2 adversarial reviewers (REVIEW-STANDARD); verification ${tryCmd('BASE_TIP', 'FIX_HEAD', g)} must be strict DIFFERENT in the improvement direction; PR with the receipt, ready-to-land, ${LAB} sheriff set ${g.id} assigned --reason <PR url>; up to ${FIX_ATTEMPTS} fix attempts`)
  steps.push(`no verified fix by ${deadline(g.alert_at, SLO_HOURS.fix)}: ${baseBranch(g) === 'main' ? 'main is nightly, fix forward: no revert, report to the Performance Lead' : `revert only with ${revertCmd(g.culprit_pr)} (culprit PR #${g.culprit_pr || 'N'}), then ${LAB} sheriff set ${g.id} assigned --reason <revert PR url>`}`)
  return steps
}

function planFor(g) {
  const steps = [`${LAB} sheriff take ${g.id} (claims the group for this session; another session's live claim skips it)`]
  if (g.state === 'new') {
    steps.push(`confirm: ${tryCmd(g.range_good, g.range_bad, g)}; strict DIFFERENT in the regression direction: ${LAB} sheriff set ${g.id} triaged; strict SAME: ${LAB} sheriff set ${g.id} invalid --reason <receipt>; else the group stays new for the next pass`)
  }
  if (g.state !== 'culprit') {
    steps.push(`bisect: read job ${g.bisect_job || '(not started yet)'} in ${LAB} alerts --json; a culprit goes on in this pass, a running bisect waits for the next pass`)
  }
  steps.push(...culpritSteps(g))
  return {
    group: g.id,
    state: g.state,
    what: `${g.story}.${g.metric} @${g.host_class}: ${g.delta_pct}% ${g.direction || ''} in ${g.range_good}..${g.range_bad}`.replace(/\s+/g, ' '),
    deadlines: { triage: deadline(g.alert_at, SLO_HOURS.triage), culprit: deadline(g.alert_at, SLO_HOURS.culprit), fix: deadline(g.alert_at, SLO_HOURS.fix) },
    steps,
  }
}

function renderPlan(p) {
  return [`Plan ${p.group} [${p.state}] ${p.what}`, `  SLO: triage by ${p.deadlines.triage}, culprit by ${p.deadlines.culprit}, fix or flag-off by ${p.deadlines.fix}`,
    ...p.steps.map((s, i) => `  ${i + 1}. ${s}`)].join('\n')
}

function forbiddenFiles(files) { return (files || []).filter(f => FORBIDDEN_FILE.test(f)) }

// ---- schemas ----

const S = { type: 'array', items: { type: 'string' } }
const GROUP = { type: 'object', properties: {
  id: { type: 'integer' }, state: { type: 'string', enum: ['new', 'triaged', 'culprit'] },
  story: { type: 'string' }, metric: { type: 'string' }, host_class: { type: 'string' },
  direction: { type: 'string', description: 'regression direction of the metric: up or down' },
  delta_pct: { type: 'number' }, range_good: { type: 'string' }, range_bad: { type: 'string' },
  alert_at: { type: 'string', description: 'ISO 8601' }, owner: { type: 'string' }, base_branch: { type: 'string' },
  bisect_job: { type: 'string' }, culprit_sha: { type: 'string' },
  culprit_verified: { type: 'string', enum: ['verified', 'unverified', 'none'] }, culprit_pr: { type: 'integer' },
  traces: S, issue: { type: 'string' } },
  required: ['id', 'state', 'story', 'metric', 'host_class', 'direction', 'delta_pct', 'range_good', 'range_bad', 'alert_at', 'bisect_job', 'culprit_sha', 'culprit_verified', 'culprit_pr', 'traces'] }
const QUEUE = { type: 'object', properties: { groups: { type: 'array', items: GROUP }, raw_count: { type: 'integer' } }, required: ['groups', 'raw_count'] }
const TRIAGE = { type: 'object', properties: {
  route: { type: 'string', enum: ['culprit', 'bisect-wait', 'invalid', 'unconfirmed', 'held'] },
  group: GROUP, receipt: { type: 'string' }, note: { type: 'string' } }, required: ['route', 'group', 'receipt', 'note'] }
const CULPRIT = { type: 'object', properties: {
  route: { type: 'string', enum: ['flag-off', 'fix', 'unverified', 'held'] }, feature: { type: 'string' },
  culprit_pr: { type: 'integer' }, receipts: { type: 'string' }, note: { type: 'string' } }, required: ['route', 'feature', 'culprit_pr', 'receipts', 'note'] }
const PR = { type: 'object', properties: { pr_url: { type: 'string' }, branch: { type: 'string' }, head_sha: { type: 'string' },
  state_set: { type: 'boolean' }, note: { type: 'string' } }, required: ['pr_url', 'branch', 'head_sha', 'state_set', 'note'] }
const FIX = { type: 'object', properties: { branch: { type: 'string' }, base_sha: { type: 'string' }, head_sha: { type: 'string' },
  files_changed: S, cause: { type: 'string' }, summary: { type: 'string' }, tests: { type: 'string' }, owner_told: { type: 'string' },
  gave_up: { type: 'string', description: 'empty, or why no principled fix fits this slice' } },
  required: ['branch', 'base_sha', 'head_sha', 'files_changed', 'cause', 'summary', 'tests', 'owner_told', 'gave_up'] }
const FIND = { type: 'object', properties: { findings: { type: 'array', items: { type: 'object', properties: {
  severity: { type: 'string', enum: ['critical', 'major', 'minor'] }, file: { type: 'string' }, line: { type: 'integer' },
  problem: { type: 'string' }, failure_scenario: { type: 'string' }, principled_fix: { type: 'string' } },
  required: ['severity', 'file', 'problem', 'failure_scenario', 'principled_fix'] } } }, required: ['findings'] }
const VERIFY = { type: 'object', properties: { verdict: { type: 'string', enum: ['improved', 'not-improved', 'unknown'] },
  other_regressions: S, receipts: { type: 'string' } }, required: ['verdict', 'other_regressions', 'receipts'] }
const REVERTED = { type: 'object', properties: { action: { type: 'string', enum: ['reverted', 'not-yet', 'refused'] },
  pr_url: { type: 'string' }, state_set: { type: 'boolean' }, note: { type: 'string' } }, required: ['action', 'pr_url', 'state_set', 'note'] }

// ---- prompts ----

const BRIEF = `You are a step of the cmux perf-sheriff workflow (plans/cmux-next/chrome-parity/p12-perf-process.md section 3.7). Work in a checkout of manaflow-ai/cmux.
Tools: ${LAB} (alerts, sheriff, try), ${TRACE}, cmux-ci, gh, and git for your own branch. The flag-off step also runs ${GEN}; a revert runs only ${REVERT}. Use nothing else for lab data, builds or merges: no direct SQLite or labd HTTP, no maclease, no perf-cron, no local swift/xcodebuild/cargo build (compile on the fleet with cmux-ci).
Run \`${LAB} <command> --help\` before the first use of a subcommand and use its exact flags. Never pass --admin, never force push, never --no-verify, never add risk:human-ok or risk:waived, never set a group to accepted (only the Performance Lead's session may).
A try receipt line reads: \`Perf try <story>.<metric> @<host-class>: base p50/p95/p99 -> head p50/p95/p99 (delta %), MWU p, KS p, strict DIFFERENT|SAME|UNKNOWN (floored X), job <id>\`. Decide on the strict verdict. A \`lab.py try --wait\` timeout leaves the job running: wait on the same job again, never resubmit.
Run every \`${LAB} sheriff\` command as \`CMUX_AGENT_SESSION=${OPTS.session} ${LAB} sheriff ...\`: the whole pass acts as the sheriff session that started it, so its claim holds for every step. Run \`${LAB} sheriff take <group>\` again right before each \`sheriff set\` (it renews the 2 h claim); a refusal means another session holds the group: stop and say so in note.`

const NO_BAR_MOVING = `Never edit a budget, threshold, expectation, baseline, subscription, target, AnomalyConfig override, perf-gate row, the budget of a \`// perf-hot:\` marker, statistics code (perf_stats.py, anomaly*.py, pinpoint*.py) or a test's bound to clear the alert (rule R3). Never add a sleep, poll, debounce, throttle, retry or a feature flag that hides the cost. Remove the work the culprit added, or make it O(changed items) and off the main thread, per plans/cmux-next/PATTERNS.md.`

function groupLine(g) { return JSON.stringify(g) }

function queuePrompt() {
  return `${BRIEF}\nMODE: read only.\nRun \`${LAB} alerts --state ${QUEUE_STATES} --json\`. Return every group in it, mapped field for field to the schema: id is the group's integer id; range_good/range_bad are the last good and first bad commit SHAs of the group's range (the record's start_pos..end_pos are commit positions on base_branch: the commit just before start_pos is the last good one, the commit at end_pos the first bad one; resolve positions to SHAs with the lab's own commands, see \`${LAB} --help\`, or \`git rev-list --first-parent\` on origin/base_branch); story, metric and host_class are those of the group's largest regression (its first alert); delta_pct is (median_after - median_before) / median_before * 100 of that alert; alert_at is the group's created_at; direction is the direction the metric moved in the regression (up or down); bisect_job is the group's Pinpoint job id or ""; culprit_sha, culprit_verified (verified, unverified, or none when there is no culprit) and culprit_pr (the PR that merged the culprit, from \`gh api repos/manaflow-ai/cmux/commits/SHA/pulls\`, or 0) come from the group's culprit; traces are the stored trace digests or links of the group's Changes (task 157); base_branch is the branch the lab measured. raw_count is the number of groups in the command's output. Invent nothing: copy values, use "" or 0 where the record has none.`
}

function triagePrompt(g) {
  const take = `1. \`${LAB} sheriff take ${g.id}\`. If it refuses because another sheriff session holds the group, return route=held.\n`
  const confirm = g.state === 'new'
    ? `2. Confirm the alert: \`${tryCmd(g.range_good, g.range_bad, g)}\`. Strict DIFFERENT in the regression direction (${g.direction}): \`${LAB} sheriff set ${g.id} triaged\` and go on. Strict SAME: \`${LAB} sheriff set ${g.id} invalid --reason "<the receipt line>"\` and return route=invalid. Otherwise return route=unconfirmed (the group stays new; the next pass asks again, and lab.py try deduplicates the request).
3. `
    : '2. '
  return `${BRIEF}\nMODE: lab commands only; no source edits.\nGroup: ${groupLine(g)}\n${take}${confirm}Read the group again with \`${LAB} alerts --state ${QUEUE_STATES} --json\`. If its bisect has a culprit, return route=culprit with the refreshed group. If the bisect is still running, return route=bisect-wait (the next pass picks it up; do not wait in a loop). Return the try receipt lines you got in receipt.`
}

function culpritPrompt(g) {
  return `${BRIEF}\nMODE: lab commands and read-only git/gh; no source edits.\nGroup: ${groupLine(g)}\nCulprit ${g.culprit_sha} (${g.culprit_verified}).${g.state === 'culprit' ? `\n0. \`${LAB} sheriff take ${g.id}\`. If it refuses because another sheriff session holds the group, return route=held.` : ''}
1. ${g.culprit_verified === 'verified' ? 'The culprit is verified (strict rule, task 017); go to 2.' : `Re-verify: \`${tryCmd(g.culprit_sha + '^', g.culprit_sha, g)}\`. Not strict DIFFERENT in the regression direction: return route=unverified with the receipt (it stays at culprit for the Performance Lead).`}
2. Find the perfPath features the culprit may carry: \`git show --stat ${g.culprit_sha}\` and its diff; a feature counts when the commit adds or turns on its schemas/features/features.d/<name>.json default, or the changed code runs behind \`Feature.<name>\` (Swift) or the cmux-features constant (Rust), and its kind is perfPath. For each candidate X: \`${tryCmd(g.culprit_sha + '^', g.culprit_sha, g, `--feature X=off`)}\`. The head arm with X off and a strict verdict that is not DIFFERENT in the regression direction means X carries the regression: return route=flag-off, feature=X. Several carry it: return the one whose off arm is closest to the base.
3. Otherwise return route=fix, feature="".
culprit_pr: the PR that merged ${g.culprit_sha} (\`gh api repos/manaflow-ai/cmux/commits/${g.culprit_sha}/pulls\`), or 0. Return every receipt line in receipts.`
}

function flagOffPrompt(g, c) {
  const branch = `perf-sheriff/${g.id}-${c.feature}-off`
  return `${BRIEF}\nMODE: one source change in your own worktree.\nGroup: ${groupLine(g)}\nThe perfPath feature ${c.feature} carries the regression. Receipts:\n${c.receipts}
1. \`git fetch origin ${baseBranch(g)}\` and \`git switch -c ${branch} origin/${baseBranch(g)}\`.
2. In schemas/features/features.d/${c.feature}.json set every default that is true to false. Change nothing else in it.
3. \`${GEN}\`, then \`${GEN} --check\` (exit 0). Commit the JSON and every file the generator changed in one commit: "features: turn ${c.feature} off by default (perf ${g.id})". Push the branch (plain push; the pre-push hooks run).
4. \`gh pr create --repo manaflow-ai/cmux --base ${baseBranch(g)} --head ${branch} --label risk:normal\`. Body (STYLE.md): what regressed (${g.story}.${g.metric} @${g.host_class}, ${g.delta_pct}%), the receipts, that the off arm recovers, the line "Takes back #${c.culprit_pr || 'N'}: ${g.story}.${g.metric} regressed ${g.delta_pct}% on ${g.host_class}; ${c.feature} off recovers it (lab group ${g.id})", "## Changelog" with "Changed: ${c.feature} is off by default again while its regression is fixed." (or none if the feature is not user-visible), and "### Observed / Not run".
5. One independent review agent of the PR head (skills/cmux-review/SKILL.md, correctness first). SHIP: add the ready-to-land label. Not SHIP: fix the finding, push, review again.
6. \`${LAB} sheriff set ${g.id} assigned --reason <PR url>\`, then \`${LAB} sheriff set ${g.id} flag-off --reason "${c.feature} off by default in <PR url>"\`. state_set is true only when both succeeded.`
}

function fixPrompt(g, c, attempt, last) {
  const branch = `perf-sheriff/${g.id}-fix${attempt}`
  return `${BRIEF}\nMODE: fixer, in your own worktree.\nGroup: ${groupLine(g)}\nCulprit ${g.culprit_sha} (PR #${c.culprit_pr || '?'}); receipts:\n${c.receipts}\nAttempt ${attempt} of ${FIX_ATTEMPTS}.${last ? `\nThe previous attempt was rejected: ${JSON.stringify(last).slice(0, 4000)}` : ''}
${NO_BAR_MOVING}
1. \`git fetch origin ${baseBranch(g)}\` and \`git switch -c ${branch} origin/${baseBranch(g)}\` (a fresh branch: a rejected attempt is not built on); record base_sha.
2. Find the cause from the stored traces of ${g.culprit_sha}^ and ${g.culprit_sha} (digests: ${JSON.stringify(g.traces)}; fetch each from the link in the group record). Run \`${TRACE} summary <dir>\` on both and compare: the stall stacks, input to commit per action, and cross-process waits that appear only with the culprit. Name the cause in cause, with the trace evidence.
3. Make the principled fix (plans/cmux-next/REVIEW-STANDARD.md). If the correct fix is larger than this slice, say so in gave_up and change nothing. If the cause is in an area of plans/cmux-next/OWNERS.md, tell the owner (cmux notify or their session) and name them in owner_told.
4. Add a regression test that fails without the fix where the cost has a behavioral signature (work count, main-thread calls, allocations); run it red and green on the fleet with cmux-ci (\`cmux-ci run --class isolated ... --ref SHA\`), and compile on the fleet (\`cmux-ci build cmux --ref SHA\`). Write the commands and results in tests.
5. Commit, push the branch (plain push), and list every changed path in files_changed (\`git diff --name-only BASE_SHA HEAD\`).`
}

function reviewPrompt(g, f, lens) {
  const lenses = {
    correctness: 'Correctness: trace each changed path end to end (every entrypoint, both web engines, macOS 14/15/26/27), races, reentrancy, lifetimes, error and cancel paths. Does the fix remove the cause the traces show, for every path that hits it?',
    principled: `Root cause and no bar moving: does the change remove the cost, or move or hide it (later frame, other thread with the same wait, sleep, poll, debounce, throttle, retry, flag)? ${NO_BAR_MOVING} Check \`git diff --name-only\` and every changed \`// perf-hot:\` line yourself; any one of them is a critical finding. Does the regression test fail without the fix?`,
  }
  return `${BRIEF}\nMODE: read only.\nYou are an adversarial reviewer (${lens}) of the perf fix for group ${g.id} (${g.story}.${g.metric}, culprit ${g.culprit_sha}). Branch ${f.branch}: \`git fetch origin ${f.branch}\` and read \`git diff ${f.base_sha}..${f.head_sha}\`. The fixer says the cause is: ${f.cause}\n${lenses[lens]}\nTry to break it: give each real problem with file, line, a concrete failure scenario and the principled fix. No style nits. Return an empty list only if you cannot find a real problem.`
}

function applyPrompt(g, f, findings) {
  return `${BRIEF}\nMODE: fixer, in your own worktree.\n${NO_BAR_MOVING}\n\`git fetch origin ${f.branch}\`, continue on it (base_sha stays ${f.base_sha}) and apply these review findings for group ${g.id} with principled fixes, keeping the regression test red without the fix and green with it (fleet, cmux-ci): ${JSON.stringify(findings).slice(0, 10000)}\nCommit, push (plain), and return the new head_sha and every changed path since ${f.base_sha} in files_changed.`
}

function verifyPrompt(g, f) {
  return `${BRIEF}\nMODE: lab commands only.\nVerify the perf fix for group ${g.id}: \`${tryCmd(f.base_sha, f.head_sha, g)}\`.
improved: the ${g.story}.${g.metric} line is strict DIFFERENT in the improvement direction (opposite of ${g.direction}). not-improved: strict SAME, or DIFFERENT the wrong way. unknown: anything else. List every other metric that is strict DIFFERENT in its regression direction in other_regressions. Return every receipt line in receipts.`
}

function prPrompt(g, c, f, v) {
  return `${BRIEF}\nMODE: open the PR for a verified perf fix; no source edits.\nGroup ${g.id}, branch ${f.branch} at ${f.head_sha} (base ${f.base_sha}).
1. \`gh pr create --repo manaflow-ai/cmux --base ${baseBranch(g)} --head ${f.branch} --label risk:normal\` (risk:high instead if docs/ci/risk-tiers.md puts a changed path in the high tier). Body (STYLE.md): the regression (${g.story}.${g.metric} @${g.host_class}, ${g.delta_pct}%, culprit ${g.culprit_sha} from #${c.culprit_pr || '?'}), the cause and its trace evidence (${f.cause.slice(0, 1500)}), the fix, the verification receipts:\n${v.receipts}\nthe regression test's red and green commands (${f.tests.slice(0, 1500)}), "## Changelog" (Fixed: ... or none) and "### Observed / Not run".
2. The fix passed 2 adversarial reviewers and the verification try job in this workflow: add the ready-to-land label.
3. \`${LAB} sheriff set ${g.id} assigned --reason <PR url>\`; state_set is true only when it succeeded. The lab moves the group to fixed only after the series recovers.`
}

function revertPrompt(g, c, why) {
  return `${BRIEF}\nMODE: revert decision.\nGroup ${groupLine(g)}\nNo verified fix: ${why}\nFix-or-flag deadline: ${deadline(g.alert_at, SLO_HOURS.fix)} (\`date -u\` for now).
- Before the deadline: return action=not-yet; the group stays at culprit for the next pass.
- Base branch main: return action=refused (main is nightly: fix forward, CLAUDE.md).
- Culprit PR unknown (${c.culprit_pr || 0}): return action=refused.
- Else revert only with \`${revertCmd(c.culprit_pr)}\` (it opens the revert PR and lands it; add "Takes back #${c.culprit_pr}: ${g.story}.${g.metric} regressed ${g.delta_pct}% with no verified fix by the deadline" if the hold asks), then \`${LAB} sheriff set ${g.id} assigned --reason <revert PR url>\`. Return action=reverted.`
}

// ---- pass ----

phase('Queue')
if (!OPTS.dryRun && !SESSION_ID.test(OPTS.session)) {
  return { error: 'a live pass needs {session: "<the calling sheriff session id>"} (letters, digits and ._:@-); --dry-run needs none' }
}
let queue = OPTS.groups
if (!queue) {
  const q = await agent(queuePrompt(), { label: 'queue', phase: 'Queue', schema: QUEUE })
  if (!q) return { error: 'could not read the alert queue' }
  if (q.groups.length !== q.raw_count) log(`queue: the lab listed ${q.raw_count} groups but ${q.groups.length} mapped; the rest are not in this pass`)
  queue = q.groups
}
if (OPTS.only) {
  const before = queue.length
  queue = queue.filter(g => OPTS.only.includes(String(g.id)))
  log(`only ${OPTS.only.join(', ')}: ${queue.length} of ${before} groups in this pass`)
}
const plans = queue.map(planFor)
for (const p of plans) log(renderPlan(p))
if (OPTS.dryRun) return { dryRun: true, groups: queue.length, plans }
if (!queue.length) return { groups: 0, results: [] }

async function triage(g) {
  if (g.state === 'culprit') return { route: 'culprit', group: g, receipt: '', note: 'already at culprit' }
  const t = await agent(triagePrompt(g), { label: `triage:${g.id}`, phase: 'Triage', schema: TRIAGE })
  return t || { route: 'unconfirmed', group: g, receipt: '', note: 'triage agent failed' }
}

async function culprit(t) {
  if (t.route !== 'culprit') return { group: t.group, outcome: t.route, receipts: t.receipt, note: t.note }
  const g = t.group
  const c = await agent(culpritPrompt(g), { label: `culprit:${g.id}`, phase: 'Culprit', schema: CULPRIT })
  if (!c) return { group: g, outcome: 'culprit-check-failed', receipts: t.receipt, note: 'culprit agent failed' }
  return { group: g, outcome: c.route, culprit: c, receipts: [t.receipt, c.receipts].filter(Boolean).join('\n'), note: c.note }
}

async function fixLoop(g, c) {
  let last = null
  for (let attempt = 1; attempt <= FIX_ATTEMPTS; attempt++) {
    let f = await agent(fixPrompt(g, c, attempt, last), { label: `fix${attempt}:${g.id}`, phase: 'Fix', schema: FIX, isolation: 'worktree' })
    if (!f) return { ok: false, why: `fix attempt ${attempt}: fixer failed`, last }
    if (f.gave_up) return { ok: false, why: `fixer: ${f.gave_up}`, last: f }
    for (let round = 1; round <= REVIEW_ROUNDS; round++) {
      const bad = forbiddenFiles(f.files_changed)
      const reviews = await parallel(['correctness', 'principled'].map(lens => () =>
        agent(reviewPrompt(g, f, lens), { label: `review-${lens}${round}:${g.id}`, phase: 'Review', schema: FIND })))
      const findings = reviews.filter(Boolean).flatMap(r => r.findings).filter(x => x.severity !== 'minor')
      if (bad.length) findings.unshift({ severity: 'critical', file: bad[0], problem: `the fix edits ${bad.join(', ')}: a budget, threshold or expectation (R3)`, failure_scenario: 'the alert clears while the cost stays', principled_fix: 'revert those files and remove the cost in the code' })
      if (!findings.length) break
      if (round === REVIEW_ROUNDS) { last = { review_findings: findings }; f = null; break }
      f = await agent(applyPrompt(g, f, findings), { label: `apply${round}:${g.id}`, phase: 'Review', schema: FIX, isolation: 'worktree' }) || f
    }
    if (!f) continue
    const v = await agent(verifyPrompt(g, f), { label: `verify${attempt}:${g.id}`, phase: 'Verify', schema: VERIFY })
    if (v && v.verdict === 'improved' && !v.other_regressions.length) return { ok: true, fix: f, verify: v }
    last = { cause: f.cause, head_sha: f.head_sha, verify: v }
  }
  return { ok: false, why: `no verified fix in ${FIX_ATTEMPTS} attempts`, last }
}

async function act(r) {
  if (!r || !r.culprit) return r
  const g = r.group, c = r.culprit
  if (c.route === 'flag-off') {
    const pr = await agent(flagOffPrompt(g, c), { label: `flag-off:${g.id}`, phase: 'Flag off', schema: PR, isolation: 'worktree' })
    return { ...r, outcome: pr && pr.state_set ? 'flag-off' : 'flag-off-incomplete', pr }
  }
  if (c.route !== 'fix') return r
  const fx = await fixLoop(g, c)
  if (fx.ok) {
    const pr = await agent(prPrompt(g, c, fx.fix, fx.verify), { label: `pr:${g.id}`, phase: 'Verify', schema: PR })
    return { ...r, outcome: pr && pr.state_set ? 'assigned' : 'fix-pr-incomplete', fix: fx.fix, verify: fx.verify, pr }
  }
  const rv = await agent(revertPrompt(g, c, fx.why), { label: `revert:${g.id}`, phase: 'Verify', schema: REVERTED })
  return { ...r, outcome: rv ? `no-fix:${rv.action}` : 'no-fix', why: fx.why, last: fx.last, revert: rv }
}

const results = await pipeline(queue, triage, culprit, act)
const summary = results.map((r, i) => ({ group: queue[i].id, outcome: r ? r.outcome : 'failed', pr: r && r.pr ? r.pr.pr_url : (r && r.revert ? r.revert.pr_url : ''), note: r ? (r.note || r.why || '') : '' }))
for (const s of summary) log(`${s.group}: ${s.outcome}${s.pr ? ' ' + s.pr : ''}`)
return { groups: queue.length, summary, results }
