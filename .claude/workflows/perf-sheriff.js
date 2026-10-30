export const meta = {
  name: 'perf-sheriff',
  description: 'One perf-sheriff pass over the lab alert queue: take, confirm with a try job, wait for the bisect, read the culprit, then open one flag-off or fix PR per culprit (2 adversarial reviewers and a verification try job for a fix), and close flag-off groups whose merged PR recovered the series. --dry-run prints one plan per group.',
  whenToUse: 'A rotating sheriff session works the MQ10 queue, `lab.py sheriff list --state new,triaged,bisecting,culprit --json` (the lab store is $CMUX_PERF_LAB_DB). The pass acts as the session its first step reads from its own environment; a session is never an argument, and the Performance Lead runs it from a sheriff session. Pass "--dry-run" or {dryRun: true} to print the plans only; {only: [group ids]} limits the pass (the canary); {groups: [...]} plans a saved queue without reading the lab.',
  phases: [
    { title: 'Queue', detail: 'own session, lab.py commands, lab.py sheriff list and alert details' },
    { title: 'Triage', detail: 'take the group, confirm it with a try job, start and wait for the bisect' },
    { title: 'Culprit', detail: 'strict re-verify an unverified culprit; perfPath check with --feature X=off' },
    { title: 'Flag off', detail: 'one PR per culprit that flips the feature default, gen-features.py, risk label, take-back line, assigned' },
    { title: 'Fix', detail: 'one fixer per culprit from the stored traces (task 157)' },
    { title: 'Review', detail: '2 adversarial reviewers per REVIEW-STANDARD; R3 check on the computed diff' },
    { title: 'Verify', detail: 'verification try job, PR, assigned; revert only through gh-merge-green --revert' },
    { title: 'Follow up', detail: 'merged flag-off PR and a recovery try job: flag-off' },
  ],
}

// Chromium's perf sheriff rotation (docs/speed/perf_regression_sheriffing.md): triage each alert
// group, let Pinpoint bisect it, then turn the culprit's feature off first (Finch kill,
// components/variations) or get the culprit fixed or reverted; the bug closes after the kill is
// applied. Design: section 3.7 of plans/cmux-next/chrome-parity/p12-perf-process.md. State changes go
// only through `lab.py sheriff` (task 019): `take` claims a group for the acting session (a 2 h lease, no
// state move), `set` moves it. Try jobs only through `lab.py try` (task 018), bisects through `lab.py
// bisect` (task 016).

const LAB = 'python3 scripts/perf-lab/lab.py'
const TRACE = 'python3 scripts/cmux-next/trace.py'
const GEN = 'python3 scripts/cmux-next/gen-features.py'
const REPO = 'manaflow-ai/cmux'
const MERGE_GREEN = 'scripts/gh-merge-green'
function revertCmd(pr) { return `${MERGE_GREEN} --revert ${REPO}#${pr || 'N'}` }
const QUEUE_STATES = 'new,triaged,bisecting,culprit'
// Commands the pass runs. lab.py dispatches only modules that declare LAB_COMMANDS.
const NEEDED = { dry: ['sheriff', 'alerts'], live: ['sheriff', 'alerts', 'try'] }
const ATTEMPTS = 20
const FIX_ATTEMPTS = 2
const REVIEW_ROUNDS = 2
const BISECT_WAIT_HOURS = 3
// Section 3.7 SLOs from the alert time. sheriff.py owns the SLO report; the plan only prints the deadlines.
const SLO_HOURS = { triage: 1, culprit: 4, fix: 12 }
// try_admission.py refuses any --base/--head that is not a full commit SHA.
const SHA40 = /^[0-9a-f]{40}$/
const HEX40 = '^[0-9a-f]{40}$'
const HEX40_OR_EMPTY = '^([0-9a-f]{40})?$'
const SESSION_ID = /^[A-Za-z0-9][A-Za-z0-9._:@-]{0,127}$/
// The reason of the move to assigned names the PR; a later pass reads it back from `sheriff history`.
const REASON = { flagOff: 'perf-sheriff flag-off', fix: 'perf-sheriff fix', revert: 'perf-sheriff revert' }
const FLAG_OFF_REASON = /^perf-sheriff flag-off ([A-Za-z0-9._-]+) (https:\/\/github\.com\/manaflow-ai\/cmux\/pull\/(\d+))\s*$/

// R3: an alert is never cleared by moving the bar. A fix that touches a file that holds a perf bar
// (data, gate rows, statistics) is refused before any try job. Source files whose names merely say
// "budget" (MainFrameBudget.swift, kitty_budget.rs) hold the code a fix may need to change; the
// principled reviewer checks their constants and `// perf-hot:` budgets.
const FORBIDDEN_FILES = [
  /^scripts\/perf-lab\/(perf_stats|anomaly[\w-]*|pinpoint[\w-]*|verify|expectations)\.py$/,
  /^scripts\/perf-lab\/(subscriptions|targets|shard_map|expectations)\.json$/,
  /^scripts\/perf-lab\/stories\.d\//,
  /^scripts\/cmux-next\/(perf-hot-benches\.json|perf-gate\.py|idle-budget\.py)$/,
  /^scripts\/cmux-next\/perf-budgets[^/]*(\/|$)/,
  /^scripts\/perf-bench\/(budget\.py|budgets[^/]*\.json)$/,
  /^scripts\/ci\/launch_budget_gate\.py$/,
  /^\.github\/workflows\/[^/]*perf[^/]*$/,
  /(^|\/)baselines?\//,
  /(^|\/)[^/]*(budget|threshold|expectation|baseline)[^/]*\.(json|tsv|csv|toml|ya?ml|txt)$/i,
]
function forbiddenFiles(files) {
  return [...new Set((files || []).filter(f => FORBIDDEN_FILES.some(re => re.test(f))))]
}

const OPTS = parseOpts(args)
// The acting session, read by the first step from its own environment (never from args).
let ACTOR = ''

// ---- plan (pure: the dry run and the live pass print the same plan) ----

function parseOpts(a) {
  const o = { dryRun: false, only: null, groups: null, followups: null, sessionArg: false }
  if (a == null) return o
  if (typeof a === 'string' || Array.isArray(a)) {
    const words = (Array.isArray(a) ? a.map(String) : a.split(/\s+/)).filter(Boolean)
    o.dryRun = words.includes('--dry-run')
    o.sessionArg = words.some(w => w === '--session' || w.startsWith('--session='))
    const ids = words.filter(w => !w.startsWith('--'))
    if (ids.length) o.only = ids
    return o
  }
  o.dryRun = Boolean(a.dryRun || a['dry-run'])
  o.sessionArg = Object.prototype.hasOwnProperty.call(a, 'session')
  if (Array.isArray(a.only) && a.only.length) o.only = a.only.map(String)
  else if (a.only != null && !Array.isArray(a.only)) o.only = [String(a.only)]
  if (Array.isArray(a.groups)) o.groups = a.groups
  if (Array.isArray(a.followups)) o.followups = a.followups
  return o
}

function deadline(alertAt, hours) {
  const t = new Date(alertAt).getTime()
  return Number.isFinite(t) ? new Date(t + hours * 3600000).toISOString() : 'unknown (no alert_at)'
}

function baseBranch(g) { return g.base_branch || 'feat-cmux-next' }
function short(sha) { return (sha || 'C').slice(0, 7) }
function sheriffCmd() { return ACTOR ? `CMUX_AGENT_SESSION=${ACTOR} ${LAB} sheriff` : `${LAB} sheriff` }
function tryPrefix() { return ACTOR ? `CMUX_AGENT_SESSION=${ACTOR} CMUX_TRY_SESSION=${ACTOR} ${LAB} try` : `${LAB} try` }
function storiesOf(groups) { return [...new Set(groups.map(g => g.story))].join(',') }
function ids(groups) { return groups.map(g => g.id).join(', ') }
function improvement(direction) { return direction === 'down' ? 'up' : 'down' }

function tryCmd(base, head, stories, extra) {
  return `${tryPrefix()} --base ${base} --head ${head} --stories ${stories} --attempts ${ATTEMPTS}${extra ? ' ' + extra : ''} --wait`
}

function takeEach(groups) { return groups.map(g => `\`${sheriffCmd()} take ${g.id}\``).join(', ') }

// A group is usable only with full SHAs: try admission refuses anything shorter.
function groupProblem(g) {
  if (!g || !Number.isInteger(g.id)) return 'no integer id'
  for (const k of ['range_good', 'range_bad']) if (!SHA40.test(g[k] || '')) return `${k} is not a full 40-hex SHA`
  if (g.state === 'culprit' && !(SHA40.test(g.culprit_sha || '') && SHA40.test(g.culprit_parent_sha || ''))) {
    return 'culprit_sha and culprit_parent_sha must be full 40-hex SHAs'
  }
  return ''
}

function culpritSteps(g) {
  const c = g.culprit_sha || 'C', p = g.culprit_parent_sha || 'C^'
  const steps = []
  if (g.culprit_verified !== 'verified') {
    steps.push(`re-verify the culprit (strict rule): ${tryCmd(p, c, g.story)}; strict DIFFERENT in the regression direction goes on, anything else stays at culprit and goes to the Performance Lead`)
  }
  steps.push(`perfPath check: for each perfPath feature in schemas/features/features.d/ that ${short(c)} adds, turns on or gates code in, ${tryCmd(p, c, g.story, '--feature X=off')}; the head arm with X off not DIFFERENT from the base arm means the feature carries the regression`)
  steps.push(`groups with the same culprit and route share one PR; take every one of them first`)
  steps.push(`if a feature carries it: branch perf-sheriff/${short(c)}-X-off-<base7> on ${baseBranch(g)} that sets the feature's on defaults to false in schemas/features/features.d/X.json, ${GEN}, ${GEN} --check, commit the JSON and generated files; one review agent; take again, gh pr create with risk:normal and "Takes back #${g.culprit_pr || 'N'}: <story>.<metric> regressed <delta> on <host class>, receipt <try receipt>", ${LAB} sheriff set ${g.id} assigned --reason "${REASON.flagOff} X <PR url>", then ${landing(g)}`)
  steps.push(`a later pass, after the flag-off PR merged (gh pr view --json mergedAt) and a try job of its merge commit M^ vs M is strict DIFFERENT in the improvement direction: ${LAB} sheriff set ${g.id} flag-off --reason "X off by default in <PR url>"`)
  steps.push(`else: fixer agent from the stored traces of ${short(c)}^ and ${short(c)} (${TRACE} summary), never edits budgets, thresholds or expectations; ${REVIEW_ROUNDS} rounds of 2 adversarial reviewers (REVIEW-STANDARD) and the R3 check on git diff --name-only; verification ${tryCmd('<base_sha>', '<head_sha>', g.story)} must be strict DIFFERENT in the improvement direction; take again, PR with the receipt, ${LAB} sheriff set ${g.id} assigned --reason "${REASON.fix} <PR url>", then ${landing(g)}; up to ${FIX_ATTEMPTS} fix attempts`)
  steps.push(`no verified fix by ${deadline(g.alert_at, SLO_HOURS.fix)}: ${baseBranch(g) === 'main' ? 'main is nightly, fix forward: no revert, report to the Performance Lead' : `revert only with ${revertCmd(g.culprit_pr)} (culprit PR #${g.culprit_pr || 'N'}), then ${LAB} sheriff set ${g.id} assigned --reason "${REASON.revert} <revert PR url>"`}`)
  return steps
}

function landing(g) {
  return baseBranch(g) === 'main'
    ? `${MERGE_GREEN} ${REPO}#<PR> (main lands through gh-merge-green)`
    : 'the ready-to-land label (next-autoland lands it)'
}

function planFor(g) {
  const steps = [`${LAB} sheriff take ${g.id} (claims the group for this session; another session's live claim skips it)`]
  if (g.state === 'new') {
    steps.push(`confirm: ${tryCmd(g.range_good, g.range_bad, g.story)}; strict DIFFERENT in the regression direction: ${LAB} sheriff set ${g.id} triaged; strict SAME: ${LAB} sheriff set ${g.id} invalid --reason <receipt>; else the group stays new for the next pass`)
  }
  if (g.state !== 'culprit') {
    steps.push(`bisect: ${g.bisect_job ? `wait on job ${g.bisect_job}` : `start it with ${LAB} bisect and ${LAB} sheriff set ${g.id} bisecting`}, waiting on the job at most ${BISECT_WAIT_HOURS} h in this pass; a culprit: ${LAB} sheriff set ${g.id} culprit --culprit <sha> and go on in this pass; no culprit: back to triaged with the reason`)
  }
  steps.push(...culpritSteps(g))
  return {
    group: g.id,
    state: g.state,
    what: `${g.story}.${g.metric} @${g.host_class}: ${g.delta_pct}% ${g.direction || ''} in ${short(g.range_good)}..${short(g.range_bad)}`.replace(/\s+/g, ' '),
    deadlines: { triage: deadline(g.alert_at, SLO_HOURS.triage), culprit: deadline(g.alert_at, SLO_HOURS.culprit), fix: deadline(g.alert_at, SLO_HOURS.fix) },
    steps,
  }
}

function renderPlan(p) {
  return [`Plan ${p.group} [${p.state}] ${p.what}`, `  SLO: triage by ${p.deadlines.triage}, culprit by ${p.deadlines.culprit}, fix or flag-off by ${p.deadlines.fix}`,
    ...p.steps.map((s, i) => `  ${i + 1}. ${s}`)].join('\n')
}

// One flag-off follow-up per PR: every group the PR was opened for moves together.
function followupClusters(followups) {
  const by = new Map()
  for (const fu of followups) {
    const m = FLAG_OFF_REASON.exec(fu.reason || '')
    if (!m) continue
    const key = m[2]
    if (!by.has(key)) by.set(key, { feature: m[1], pr_url: m[2], pr: Number(m[3]), groups: [] })
    by.get(key).groups.push(fu)
  }
  return [...by.values()]
}

function renderFollowup(f) {
  return `Follow-up #${f.pr} (groups ${ids(f.groups)}): ${f.feature} off in ${f.pr_url}; once merged and a try job of its merge commit M^ vs M is strict DIFFERENT in the improvement direction, ${LAB} sheriff set <group> flag-off --reason "${f.feature} off by default in ${f.pr_url}" for each`
}

// One action per culprit: several stories and host classes often regress on the same commit.
function culpritClusters(routed) {
  const by = new Map()
  for (const r of routed) {
    if (!r || !r.culprit || !['flag-off', 'fix'].includes(r.culprit.route)) continue
    const g = r.group, c = r.culprit
    const key = [baseBranch(g), g.culprit_sha, c.route, c.route === 'flag-off' ? c.feature : ''].join('|')
    if (!by.has(key)) by.set(key, { key, route: c.route, feature: c.route === 'flag-off' ? c.feature : '', groups: [], receipts: [], culprit_pr: 0 })
    const cl = by.get(key)
    cl.groups.push(g)
    if (r.receipts) cl.receipts.push(r.receipts)
    cl.culprit_pr = cl.culprit_pr || c.culprit_pr || g.culprit_pr || 0
  }
  return [...by.values()].map(cl => {
    const groups = [...cl.groups].sort((a, b) => Math.abs(b.delta_pct) - Math.abs(a.delta_pct))
    const lead = groups[0]
    return { ...cl, groups, lead, stories: storiesOf(groups), base: baseBranch(lead), culprit_sha: lead.culprit_sha,
      culprit_parent_sha: lead.culprit_parent_sha, tag: `${short(lead.culprit_sha)}-${cl.feature || 'fix'}`,
      receipts: [...new Set(cl.receipts)].join('\n') }
  })
}

// ---- schemas ----

const S = { type: 'array', items: { type: 'string' } }
const GROUP = { type: 'object', properties: {
  id: { type: 'integer' }, state: { type: 'string', enum: ['new', 'triaged', 'bisecting', 'culprit'] },
  story: { type: 'string' }, metric: { type: 'string' }, host_class: { type: 'string' },
  direction: { type: 'string', enum: ['up', 'down'], description: 'regression direction of the metric' },
  delta_pct: { type: 'number' }, range_good: { type: 'string', pattern: HEX40 }, range_bad: { type: 'string', pattern: HEX40 },
  alert_at: { type: 'string', description: 'ISO 8601' }, owner: { type: 'string' }, base_branch: { type: 'string' },
  bisect_job: { type: 'string' }, culprit_sha: { type: 'string', pattern: HEX40_OR_EMPTY },
  culprit_parent_sha: { type: 'string', pattern: HEX40_OR_EMPTY },
  culprit_verified: { type: 'string', enum: ['verified', 'unverified', 'none'] }, culprit_pr: { type: 'integer' },
  traces: S, holder: { type: 'string' } },
  required: ['id', 'state', 'story', 'metric', 'host_class', 'direction', 'delta_pct', 'range_good', 'range_bad', 'alert_at', 'base_branch', 'bisect_job', 'culprit_sha', 'culprit_parent_sha', 'culprit_verified', 'culprit_pr', 'traces'] }
const FOLLOWUP = { type: 'object', properties: {
  id: { type: 'integer' }, reason: { type: 'string' }, story: { type: 'string' }, metric: { type: 'string' },
  host_class: { type: 'string' }, direction: { type: 'string', enum: ['up', 'down'] }, base_branch: { type: 'string' } },
  required: ['id', 'reason', 'story', 'metric', 'host_class', 'direction', 'base_branch'] }
const QUEUE = { type: 'object', properties: {
  session: { type: 'string' }, lead_session: { type: 'string' }, lab_db: { type: 'string' },
  missing_commands: S, error: { type: 'string', description: 'empty, or the failed command and its output' },
  groups: { type: 'array', items: GROUP }, followups: { type: 'array', items: FOLLOWUP }, raw_count: { type: 'integer' } },
  required: ['session', 'lead_session', 'lab_db', 'missing_commands', 'error', 'groups', 'followups', 'raw_count'] }
const TRIAGE = { type: 'object', properties: {
  route: { type: 'string', enum: ['culprit', 'bisect-wait', 'invalid', 'unconfirmed', 'held'] },
  group: GROUP, receipt: { type: 'string' }, note: { type: 'string' } }, required: ['route', 'group', 'receipt', 'note'] }
const CULPRIT = { type: 'object', properties: {
  route: { type: 'string', enum: ['flag-off', 'fix', 'unverified', 'held'] }, feature: { type: 'string' },
  culprit_pr: { type: 'integer' }, receipts: { type: 'string' }, note: { type: 'string' } }, required: ['route', 'feature', 'culprit_pr', 'receipts', 'note'] }
const BRANCH_PROPS = { branch: { type: 'string' }, base_sha: { type: 'string', pattern: HEX40_OR_EMPTY },
  head_sha: { type: 'string', pattern: HEX40_OR_EMPTY }, files_changed: S,
  pr_url: { type: 'string', description: 'an open PR this branch already has, or ""' },
  held: { type: 'string', description: 'empty, or the take refusal' }, note: { type: 'string' } }
const BRANCH = { type: 'object', properties: BRANCH_PROPS, required: Object.keys(BRANCH_PROPS) }
const FIX_PROPS = { ...BRANCH_PROPS, cause: { type: 'string' }, summary: { type: 'string' }, tests: { type: 'string' },
  owner_told: { type: 'string' }, gave_up: { type: 'string', description: 'empty, or why no principled fix fits this slice' } }
const FIX = { type: 'object', properties: FIX_PROPS, required: Object.keys(FIX_PROPS) }
const PR = { type: 'object', properties: { pr_url: { type: 'string' }, held: { type: 'boolean' },
  state_set: { type: 'boolean' }, landed: { type: 'string', description: 'ready-to-land, gh-merge-green, or ""' }, note: { type: 'string' } },
  required: ['pr_url', 'held', 'state_set', 'landed', 'note'] }
const FIND = { type: 'object', properties: {
  changed_paths: { type: 'array', items: { type: 'string' }, description: 'git diff --name-only base_sha..head_sha, as computed' },
  findings: { type: 'array', items: { type: 'object', properties: {
    severity: { type: 'string', enum: ['critical', 'major', 'minor'] }, file: { type: 'string' }, line: { type: 'integer' },
    problem: { type: 'string' }, failure_scenario: { type: 'string' }, principled_fix: { type: 'string' } },
    required: ['severity', 'file', 'problem', 'failure_scenario', 'principled_fix'] } } }, required: ['changed_paths', 'findings'] }
const VERIFY = { type: 'object', properties: { verdict: { type: 'string', enum: ['improved', 'not-improved', 'unknown', 'held'] },
  other_regressions: S, receipts: { type: 'string' } }, required: ['verdict', 'other_regressions', 'receipts'] }
const REVERTED = { type: 'object', properties: { action: { type: 'string', enum: ['reverted', 'not-yet', 'refused', 'held'] },
  pr_url: { type: 'string' }, state_set: { type: 'boolean' }, note: { type: 'string' } }, required: ['action', 'pr_url', 'state_set', 'note'] }
const FOLLOWED = { type: 'object', properties: {
  action: { type: 'string', enum: ['flag-off', 'pending', 'closed', 'not-recovered', 'held'] },
  merge_sha: { type: 'string', pattern: HEX40_OR_EMPTY }, receipts: { type: 'string' }, note: { type: 'string' } },
  required: ['action', 'merge_sha', 'receipts', 'note'] }

// ---- prompts ----

function brief() {
  return `You are a step of the cmux perf-sheriff workflow (plans/cmux-next/chrome-parity/p12-perf-process.md section 3.7). Work in a checkout of ${REPO}.
Tools: ${LAB} (sheriff, alerts, try, bisect), ${TRACE}, cmux-ci, gh, and git for your own branch. The flag-off step also runs ${GEN}; a merge into main or a revert runs only ${MERGE_GREEN}. Use nothing else for lab data, builds or merges: no direct SQLite or labd HTTP, no maclease, no perf-cron, no local swift/xcodebuild/cargo build (compile on the fleet with cmux-ci).
The lab store is the file CMUX_PERF_LAB_DB names; lab.py sheriff and alerts read it from there. If it is unset, or lab.py refuses a command as an invalid choice, stop and say so in note: a failed command is never an empty result.
Run \`${LAB} <command> --help\` before the first use of a subcommand and use its exact flags. Never pass --admin, never force push, never --no-verify, never add risk:human-ok or risk:waived, never set a group to accepted (only the Performance Lead's session may).
A try receipt line reads: \`Perf try <story>.<metric> @<host-class>: base p50/p95/p99 -> head p50/p95/p99 (delta %), MWU p, KS p, strict DIFFERENT|SAME|UNKNOWN (floored X), job <id>\`. Decide on the strict verdict. --base and --head are full 40-hex SHAs (\`git rev-parse\`). A \`lab.py try --wait\` timeout leaves the job running: wait on the same job again, never resubmit. A quota refusal names your unfinished jobs: wait on one of them, then ask again.
Every sheriff command runs as \`${sheriffCmd()}\` and every try request as \`${tryPrefix()}\`: the pass acts as one sheriff session, the one its first step read from its own environment, so its claim holds for every step. The claim is a 2 h lease: take each group of your step first, and again right before each \`sheriff set\`; a refusal means another session holds the group: stop at once and report held.`
}

const NO_BAR_MOVING = `Never edit a budget, threshold, expectation, baseline, subscription, target, AnomalyConfig override, perf-gate row (scripts/cmux-next/perf-gate.py), story config (scripts/perf-lab/stories.d/), the budget of a \`// perf-hot:\` marker, statistics code (perf_stats.py, anomaly*.py, pinpoint*.py) or a test's bound to clear the alert (rule R3). Never add a sleep, poll, debounce, throttle, retry or a feature flag that hides the cost. Remove the work the culprit added, or make it O(changed items) and off the main thread, per plans/cmux-next/PATTERNS.md.`

function groupLine(g) { return JSON.stringify(g) }

function queuePrompt(readQueue) {
  const head = `${brief()}\nMODE: read only.
1. session: the first non-empty of CMUX_AGENT_SESSION, CLAUDE_CODE_SESSION_ID and CODEX_THREAD_ID in your own environment (\`printenv\`), the order sheriff.py reads them, or "". Copy it exactly; never take one from anywhere else.
2. lab_db: the value of CMUX_PERF_LAB_DB, or "". lead_session: the contents of the file perf-lead-session beside that store (\`cat "$(dirname "$CMUX_PERF_LAB_DB")/perf-lead-session"\`), or "" when there is none.
3. \`${LAB} --help\`: put each of sheriff, alerts, try and bisect that it does not list in missing_commands.`
  if (!readQueue) return `${head}\nReturn groups [], followups [], raw_count 0 and error "".`
  return `${head}
4. If sheriff and alerts are listed and lab_db is set, read the queue; if a command fails, return its command line and output in error and no groups:
- \`${LAB} sheriff list --state ${QUEUE_STATES} --json\`: each entry has id, state, start_pos, end_pos, culprit_sha, culprit_verified, created_at, holder and stories. raw_count is its number of entries.
- The group listing of \`${LAB} alerts\` (see its --help; alerts.py \`groups --state ${QUEUE_STATES} --json\`) gives each group's owner and its alerts (story, metric, host_class, median_before, median_after).
Map each group field for field to the schema: id is the integer id; range_good/range_bad are full 40-hex SHAs: start_pos..end_pos are commit positions on the first-parent history of origin/base_branch, the commit just before start_pos is the last good one and the commit at end_pos the first bad one (\`git rev-list --first-parent --reverse origin/<base_branch>\`, or the lab's own position command if --help names one); story, metric and host_class are those of the group's largest regression; delta_pct is (median_after - median_before) / median_before * 100 of that alert; direction is up when median_after > median_before, else down; alert_at is created_at; bisect_job is the group's bisect job id or ""; culprit_sha is the full 40-hex SHA (\`git rev-parse\`) or "", culprit_parent_sha is \`git rev-parse <culprit_sha>^\` or ""; culprit_verified is verified, unverified, or none without a culprit; culprit_pr is the PR that merged the culprit (\`gh api repos/${REPO}/commits/SHA/pulls\`) or 0; traces are the stored trace digests or links of the group's Changes (task 157); base_branch is the branch the lab measured; holder is the live claim holder or "".
- followups: \`${LAB} sheriff list --state assigned --json\`, then \`${LAB} sheriff history <id> --json\` for each: include a group only when the reason of its newest move to assigned starts with "${REASON.flagOff} ", with that reason copied exactly and the story, metric, host_class, direction and base_branch of its largest regression.
Invent nothing: copy values, use "" or 0 where the record has none.`
}

function triagePrompt(g) {
  const sh = sheriffCmd()
  const take = `1. \`${sh} take ${g.id}\`. If it refuses because another sheriff session holds the group, return route=held.\n`
  const confirm = g.state === 'new'
    ? `2. Confirm the alert: \`${tryCmd(g.range_good, g.range_bad, g.story)}\`. Strict DIFFERENT in the regression direction (${g.direction}): take again, \`${sh} set ${g.id} triaged\` and go on. Strict SAME: take again, \`${sh} set ${g.id} invalid --reason "<the receipt line>"\` and return route=invalid. Otherwise return route=unconfirmed (the group stays new; the next pass asks again, and lab.py try deduplicates the request).
3. `
    : '2. '
  return `${brief()}\nMODE: lab commands only; no source edits.\nGroup: ${groupLine(g)}\n${take}${confirm}The bisect (Pinpoint executor, task 016): \`${LAB} bisect --help\` names its start and wait commands. If lab.py has no bisect command, return route=bisect-wait with that in note.
- ${g.bisect_job ? `The group's bisect job is ${g.bisect_job}.` : `The group has no bisect job: start one for group ${g.id} (story ${g.story}, host class ${g.host_class}, magnitude = the alert delta).`} If \`${sh} list --state triaged --json\` still lists group ${g.id}, take again and \`${sh} set ${g.id} bisecting\`.
- Wait on the job with the executor's bounded wait (at most 30 minutes per call; a timeout leaves the job running: wait on the same job again, never start another), at most ${BISECT_WAIT_HOURS} h in all. Still running after that: return route=bisect-wait.
- The job ended with a culprit: if the group is not at culprit yet, take again and \`${sh} set ${g.id} culprit --culprit <full 40-hex SHA>\`. Read the group again (\`${LAB} sheriff list --state culprit --json\` and the alerts group listing) and return route=culprit with the refreshed group, culprit_sha and culprit_parent_sha (\`git rev-parse <sha>^\`) as full SHAs.
- The job ended with no culprit: take again, \`${sh} set ${g.id} triaged --reason "bisect <job>: no culprit (<why>)"\` and return route=unconfirmed.
Return the try receipt lines you got in receipt.`
}

function culpritPrompt(g) {
  const sh = sheriffCmd()
  return `${brief()}\nMODE: lab commands and read-only git/gh; no source edits.\nGroup: ${groupLine(g)}\nCulprit ${g.culprit_sha} (${g.culprit_verified}), parent ${g.culprit_parent_sha}.
0. \`${sh} take ${g.id}\`. If it refuses because another sheriff session holds the group, return route=held.
1. ${g.culprit_verified === 'verified' ? 'The culprit is verified (strict rule, task 017); go to 2.' : `Re-verify: \`${tryCmd(g.culprit_parent_sha, g.culprit_sha, g.story)}\`. Not strict DIFFERENT in the regression direction: return route=unverified with the receipt (it stays at culprit for the Performance Lead).`}
2. Find the perfPath features the culprit may carry: \`git show --stat ${g.culprit_sha}\` and its diff; a feature counts when the commit adds or turns on its schemas/features/features.d/<name>.json default, or the changed code runs behind \`Feature.<name>\` (Swift) or the cmux-features constant (Rust), and its kind is perfPath. For each candidate X: \`${tryCmd(g.culprit_parent_sha, g.culprit_sha, g.story, '--feature X=off')}\`. The head arm with X off and a strict verdict that is not DIFFERENT in the regression direction means X carries the regression: return route=flag-off, feature=X. Several carry it: return the one whose off arm is closest to the base.
3. Otherwise return route=fix, feature="".
culprit_pr: the PR that merged ${g.culprit_sha} (\`gh api repos/${REPO}/commits/${g.culprit_sha}/pulls\`), or 0. Return every receipt line in receipts.`
}

function clusterLine(cl) {
  return `Groups ${ids(cl.groups)} (one culprit, one change for all of them):\n${cl.groups.map(groupLine).join('\n')}\nCulprit ${cl.culprit_sha} (PR #${cl.culprit_pr || '?'}), parent ${cl.culprit_parent_sha}. Receipts:\n${cl.receipts}`
}

// A pass runs the same culprit again while it is unfixed; a branch of an earlier pass is never reused
// by a plain push, and an open PR of an earlier pass is continued, not duplicated.
function branchSteps(cl, prefix, reuseOpen) {
  return `${reuseOpen ? `An open PR of an earlier pass: \`gh pr list --repo ${REPO} --state open --json url,headRefName --jq '.[] | select(.headRefName | startswith("${prefix}-"))'\`. If there is one, fetch its branch, return its branch, base_sha (\`git merge-base origin/${cl.base} origin/<branch>\`), head_sha, files_changed and pr_url, and change nothing else.\n` : ''}A new branch: \`git fetch origin ${cl.base}\`; base_sha is \`git rev-parse origin/${cl.base}\` (40 hex); the branch is ${prefix}-<first 7 of base_sha>, and if \`git ls-remote --exit-code --heads origin <branch>\` finds it (an earlier pass), append -2, -3, ... until it does not; \`git switch -c <branch> origin/${cl.base}\`. pr_url is "".`
}

function flagOffPrompt(cl) {
  const prefix = `perf-sheriff/${short(cl.culprit_sha)}-${cl.feature}-off`
  return `${brief()}\nMODE: one source change in your own worktree.\n${clusterLine(cl)}\nThe perfPath feature ${cl.feature} carries the regression.
1. Take every group: ${takeEach(cl.groups)}. A refusal: put it in held and stop.
2. ${branchSteps(cl, prefix, true)}
3. In schemas/features/features.d/${cl.feature}.json set every default that is true to false. Change nothing else in it.
4. \`${GEN}\`, then \`${GEN} --check\` (exit 0). Commit the JSON and every file the generator changed in one commit: "features: turn ${cl.feature} off by default (perf ${ids(cl.groups)})". Push the branch (plain push; the pre-push hooks run). Return branch, base_sha, head_sha (40 hex) and files_changed (\`git diff --name-only <base_sha> HEAD\`). Do not open the PR: a later step does after review.`
}

function fixPrompt(cl, attempt, last) {
  const g = cl.lead
  const prefix = `perf-sheriff/${short(cl.culprit_sha)}-fix`
  return `${brief()}\nMODE: fixer, in your own worktree.\n${clusterLine(cl)}\nAttempt ${attempt} of ${FIX_ATTEMPTS}.${last ? `\nThe previous attempt was rejected: ${JSON.stringify(last).slice(0, 4000)}` : ''}
${NO_BAR_MOVING}
1. Take every group: ${takeEach(cl.groups)}. A refusal: put it in held and stop.
2. ${branchSteps(cl, `${prefix}${attempt}`, false)} A rejected attempt is never built on.
3. Find the cause from the stored traces of ${short(cl.culprit_sha)}^ and ${short(cl.culprit_sha)} (digests: ${JSON.stringify(g.traces)}; fetch each from the link in the group record). Run \`${TRACE} summary <dir>\` on both and compare: the stall stacks, input to commit per action, and cross-process waits that appear only with the culprit. Name the cause in cause, with the trace evidence. It must explain every story of the groups (${cl.stories}).
4. Make the principled fix (plans/cmux-next/REVIEW-STANDARD.md). If the correct fix is larger than this slice, say so in gave_up and change nothing. If the cause is in an area of plans/cmux-next/OWNERS.md, tell the owner (cmux notify or their session) and name them in owner_told.
5. Add a regression test that fails without the fix where the cost has a behavioral signature (work count, main-thread calls, allocations); run it red and green on the fleet with cmux-ci (\`cmux-ci run --class isolated ... --ref SHA\`), and compile on the fleet (\`cmux-ci build cmux --ref SHA\`). Write the commands and results in tests.
6. Commit, push the branch (plain push), and return head_sha (40 hex) and every changed path in files_changed (\`git diff --name-only <base_sha> HEAD\`).`
}

function reviewPrompt(cl, f, lens) {
  const lenses = {
    correctness: 'Correctness: trace each changed path end to end (every entrypoint, both web engines, macOS 14/15/26/27), races, reentrancy, lifetimes, error and cancel paths. Does the fix remove the cause the traces show, for every path that hits it?',
    principled: `Root cause and no bar moving: does the change remove the cost, or move or hide it (later frame, other thread with the same wait, sleep, poll, debounce, throttle, retry, flag)? ${NO_BAR_MOVING} Check every changed path and every changed \`// perf-hot:\` line and constant that sets a bar yourself; any one of them is a critical finding. Does the regression test fail without the fix?`,
    'flag-off': `Flag-off: the change must set only the true defaults of schemas/features/features.d/${cl.feature}.json to false plus the files \`${GEN}\` regenerates (\`${GEN} --check\` exits 0 at the head). The feature's kind must be perfPath; nothing else may need it on (other features' requirements, tests that assume the default). Anything else in the diff is a critical finding.`,
  }
  return `${brief()}\nMODE: read only.\nYou are an adversarial reviewer (${lens}) of the perf change for groups ${ids(cl.groups)} (${cl.stories}, culprit ${cl.culprit_sha}). Branch ${f.branch}: \`git fetch origin ${f.branch}\` and read \`git diff ${f.base_sha}..${f.head_sha}\`. Return changed_paths exactly as \`git diff --name-only ${f.base_sha}..${f.head_sha}\` prints them.${f.cause ? ` The fixer says the cause is: ${f.cause}` : ''}\n${lenses[lens]}\nTry to break it: give each real problem with file, line, a concrete failure scenario and the principled fix. No style nits. Return an empty findings list only if you cannot find a real problem.`
}

function applyPrompt(cl, f, findings) {
  return `${brief()}\nMODE: fixer, in your own worktree.\n${cl.route === 'fix' ? NO_BAR_MOVING : `Change only schemas/features/features.d/${cl.feature}.json and the files ${GEN} regenerates.`}
1. Take every group: ${takeEach(cl.groups)}. A refusal: put it in held and stop.
2. \`git fetch origin ${f.branch}\`, continue on it (base_sha stays ${f.base_sha}) and apply these review findings for groups ${ids(cl.groups)} with principled fixes${cl.route === 'fix' ? ', keeping the regression test red without the fix and green with it (fleet, cmux-ci)' : ''}: ${JSON.stringify(findings).slice(0, 10000)}
3. Commit, push (plain), and return branch, base_sha, the new head_sha, pr_url "${f.pr_url || ''}" and every changed path since ${f.base_sha} in files_changed.`
}

function verifyPrompt(cl, f) {
  const metrics = cl.groups.map(g => `${g.story}.${g.metric} @${g.host_class} (improvement direction ${improvement(g.direction)})`).join('; ')
  return `${brief()}\nMODE: lab commands only.\n1. Take every group: ${takeEach(cl.groups)}. A refusal: return verdict=held.
2. Verify the perf fix for groups ${ids(cl.groups)}: \`${tryCmd(f.base_sha, f.head_sha, cl.stories)}\`.
improved: every one of ${metrics} is strict DIFFERENT in its improvement direction. not-improved: any of them strict SAME, or DIFFERENT the wrong way. unknown: anything else. List every other metric that is strict DIFFERENT in its regression direction in other_regressions. Return every receipt line in receipts.`
}

function prPrompt(cl, f, reasonPrefix, body) {
  const sh = sheriffCmd()
  const land = cl.base === 'main'
    ? `\`${MERGE_GREEN} ${REPO}#<PR number>\` (main lands through gh-merge-green; it waits for main's required checks; never --override); landed=gh-merge-green`
    : '`gh pr edit <PR url> --add-label ready-to-land` (next-autoland lands it); landed=ready-to-land'
  return `${brief()}\nMODE: open and hand off the PR; no source edits.\nGroups ${ids(cl.groups)}, branch ${f.branch} at ${f.head_sha} (base ${f.base_sha}). It passed review in this workflow.
1. Take every group: ${takeEach(cl.groups)}. A refusal: return held=true, state_set=false, and open or label nothing.
2. ${f.pr_url ? `The PR is ${f.pr_url}; edit its body to the text below if it differs.` : `\`gh pr create --repo ${REPO} --base ${cl.base} --head ${f.branch} --label risk:normal\` (risk:high instead if docs/ci/risk-tiers.md puts a changed path in the high tier).`} Body (STYLE.md): ${body}
3. Take every group again, then for each: \`${sh} set <group> assigned --reason "${reasonPrefix} <PR url>"\`. state_set is true only when every set succeeded; on any refusal stop and leave the PR open and unlabeled.
4. Only when state_set is true: ${land}. Otherwise landed="".`
}

function flagOffBody(cl) {
  const g = cl.lead
  return `what regressed (${cl.groups.map(x => `${x.story}.${x.metric} @${x.host_class} ${x.delta_pct}%`).join(', ')}), the receipts:\n${cl.receipts}\nthat the ${cl.feature}=off arm recovers it, the line "Takes back #${cl.culprit_pr || 'N'}: ${g.story}.${g.metric} regressed ${g.delta_pct}% on ${g.host_class}; ${cl.feature} off recovers it (lab groups ${ids(cl.groups)})", "## Changelog" with "Changed: ${cl.feature} is off by default again while its regression is fixed." (or none if the feature is not user-visible), and "### Observed / Not run".`
}

function fixBody(cl, f, v) {
  return `the regression (${cl.groups.map(x => `${x.story}.${x.metric} @${x.host_class} ${x.delta_pct}%`).join(', ')}; culprit ${cl.culprit_sha} from #${cl.culprit_pr || '?'}), the cause and its trace evidence (${(f.cause || '').slice(0, 1500)}), the fix, the verification receipts:\n${v.receipts}\nthe regression test's red and green commands (${(f.tests || '').slice(0, 1500)}), "## Changelog" (Fixed: ... or none) and "### Observed / Not run".`
}

function revertPrompt(cl, why) {
  const g = cl.lead, sh = sheriffCmd()
  return `${brief()}\nMODE: revert decision.\n${clusterLine(cl)}\nNo verified fix: ${why}\nFix-or-flag deadline: ${deadline(g.alert_at, SLO_HOURS.fix)} (\`date -u\` for now).
- Take every group first: ${takeEach(cl.groups)}. A refusal: return action=held.
- Before the deadline: return action=not-yet; the groups stay at culprit for the next pass.
- Base branch main: return action=refused (main is nightly: fix forward, CLAUDE.md).
- Culprit PR unknown (${cl.culprit_pr || 0}): return action=refused.
- Else revert only with \`${revertCmd(cl.culprit_pr)}\` (it opens the revert PR and lands it; add "Takes back #${cl.culprit_pr}: ${g.story}.${g.metric} regressed ${g.delta_pct}% with no verified fix by the deadline" if the hold asks), then take again and for each group \`${sh} set <group> assigned --reason "${REASON.revert} <revert PR url>"\`. Return action=reverted; state_set is true only when every set succeeded.`
}

function followupPrompt(fu) {
  const sh = sheriffCmd()
  const metrics = fu.groups.map(g => `${g.story}.${g.metric} @${g.host_class} (improvement direction ${improvement(g.direction)})`).join('; ')
  return `${brief()}\nMODE: lab commands and read-only gh/git.\nFlag-off PR ${fu.pr_url} (${fu.feature} off) for groups ${ids(fu.groups)}: ${fu.groups.map(groupLine).join('\n')}
1. Take every group: ${takeEach(fu.groups)}. A refusal: return action=held.
2. \`gh pr view ${fu.pr_url} --json state,mergedAt,mergeCommit\`. Open: return action=pending. Closed without a merge: return action=closed (the groups stay assigned for the Performance Lead; say so in note).
3. Merged: merge_sha is mergeCommit.oid (40 hex). \`git fetch origin\`, then \`${tryCmd('<merge_sha^ as a full 40-hex SHA>', '<merge_sha>', storiesOf(fu.groups))}\`. Recovered: every one of ${metrics} is strict DIFFERENT in its improvement direction. Otherwise return action=not-recovered with the receipts (the groups stay assigned; say what is missing in note).
4. Recovered: take every group again, then for each \`${sh} set <group> flag-off --reason "${fu.feature} off by default in ${fu.pr_url} (merged <merge_sha>)"\`. Return action=flag-off only when every set succeeded. Return every receipt line in receipts.`
}

// ---- pass ----

phase('Queue')
if (OPTS.sessionArg) {
  return { error: 'the session is not an argument: the pass acts as the session its first step reads from its own environment (sheriff.py: never an argument)' }
}
let queue = OPTS.groups
let followups = OPTS.followups || []
if (!(OPTS.dryRun && queue)) {
  const q = await agent(queuePrompt(!queue), { label: 'queue', phase: 'Queue', schema: QUEUE })
  if (!q) return { error: 'could not read the alert queue' }
  const missing = (q.missing_commands || []).filter(c => NEEDED[OPTS.dryRun ? 'dry' : 'live'].includes(c))
  if (missing.length) {
    return { error: `lab.py has no ${missing.join(', ')} command: register the module in lab.py (LAB_COMMANDS with add_arguments(command, parser) and run(command, args)); the pass did nothing` }
  }
  if ((q.missing_commands || []).includes('bisect')) log('lab.py has no bisect command (task 016): new and triaged groups wait for the next pass')
  if (!queue && !q.lab_db) return { error: 'CMUX_PERF_LAB_DB is not set: lab.py sheriff and alerts need the lab store' }
  if (q.error) return { error: `the queue could not be read: ${q.error}` }
  if (!OPTS.dryRun) {
    if (!SESSION_ID.test(q.session || '')) return { error: 'a live pass needs an agent session in the environment (CMUX_AGENT_SESSION, CLAUDE_CODE_SESSION_ID or CODEX_THREAD_ID; letters, digits and ._:@-)' }
    if (q.lead_session && q.session === q.lead_session) return { error: "the pass would act as the Performance Lead's session; run it from a sheriff session" }
    ACTOR = q.session
  }
  if (!queue) {
    if (q.groups.length !== q.raw_count) log(`queue: the lab listed ${q.raw_count} groups but ${q.groups.length} mapped; the rest are not in this pass`)
    queue = q.groups
    followups = q.followups || []
  }
}
queue = queue.filter(g => {
  const why = groupProblem(g)
  if (why) log(`group ${g && g.id}: ${why}; not in this pass`)
  return !why
})
if (OPTS.only) {
  const before = queue.length
  queue = queue.filter(g => OPTS.only.includes(String(g.id)))
  followups = followups.filter(f => OPTS.only.includes(String(f.id)))
  log(`only ${OPTS.only.join(', ')}: ${queue.length} of ${before} groups in this pass`)
}
const follow = followupClusters(followups)
const plans = queue.map(planFor)
for (const p of plans) log(renderPlan(p))
for (const f of follow) log(renderFollowup(f))
const shared = new Map()
for (const g of queue) if (g.culprit_sha) shared.set(g.culprit_sha, [...(shared.get(g.culprit_sha) || []), g.id])
for (const [sha, gs] of shared) if (gs.length > 1) log(`culprit ${short(sha)} is shared by groups ${gs.join(', ')}: one flag-off or fix PR for all of them`)
if (OPTS.dryRun) return { dryRun: true, groups: queue.length, plans, followups: follow.map(f => ({ pr: f.pr_url, groups: f.groups.map(g => g.id) })) }
if (!queue.length && !follow.length) return { groups: 0, summary: [], results: [] }

async function triage(g) {
  if (g.state === 'culprit') return { route: 'culprit', group: g, receipt: '', note: 'already at culprit' }
  const t = await agent(triagePrompt(g), { label: `triage:${g.id}`, phase: 'Triage', schema: TRIAGE })
  if (!t) return { route: 'unconfirmed', group: g, receipt: '', note: 'triage agent failed' }
  if (t.route === 'culprit' && groupProblem({ ...t.group, state: 'culprit' })) {
    return { route: 'unconfirmed', group: g, receipt: t.receipt, note: `culprit not resolved to full SHAs: ${groupProblem({ ...t.group, state: 'culprit' })}` }
  }
  return t
}

async function culprit(t) {
  if (t.route !== 'culprit') return { group: t.group, outcome: t.route, receipts: t.receipt, note: t.note }
  const g = t.group
  const c = await agent(culpritPrompt(g), { label: `culprit:${g.id}`, phase: 'Culprit', schema: CULPRIT })
  if (!c) return { group: g, outcome: 'culprit-check-failed', receipts: t.receipt, note: 'culprit agent failed' }
  return { group: g, outcome: c.route, culprit: c, receipts: [t.receipt, c.receipts].filter(Boolean).join('\n'), note: c.note }
}

// Review rounds over one branch. The R3 check runs on the paths the reviewers computed from the diff,
// not only on the paths the author reported.
async function reviewed(cl, f, lenses, tag, phaseName) {
  for (let round = 1; round <= REVIEW_ROUNDS; round++) {
    const reviews = await parallel(lenses.map(lens => () =>
      agent(reviewPrompt(cl, f, lens), { label: `review-${lens}${round}:${tag}`, phase: 'Review', schema: FIND })))
    const findings = []
    reviews.forEach((r, i) => {
      if (!r) findings.push({ severity: 'major', file: '', problem: `the ${lenses[i]} review did not run`, failure_scenario: 'an unreviewed change lands', principled_fix: 'review it again' })
    })
    const done = reviews.filter(Boolean)
    findings.push(...done.flatMap(r => r.findings).filter(x => x.severity !== 'minor'))
    const bad = forbiddenFiles([...(f.files_changed || []), ...done.flatMap(r => r.changed_paths || [])])
    if (bad.length) findings.unshift({ severity: 'critical', file: bad[0], problem: `the change edits ${bad.join(', ')}: a file that holds a perf bar (R3)`, failure_scenario: 'the alert clears while the cost stays', principled_fix: 'revert those files and remove the cost in the code' })
    if (!findings.length) return { f, findings: [] }
    if (round === REVIEW_ROUNDS) return { f, findings }
    const next = await agent(applyPrompt(cl, f, findings), { label: `apply${round}:${tag}`, phase: phaseName, schema: BRANCH, isolation: 'worktree' })
    if (!next) return { f, findings }
    if (next.held) return { f, findings, held: next.held }
    f = { ...f, ...next }
  }
  return { f, findings: [] }
}

async function fixLoop(cl) {
  let last = null
  for (let attempt = 1; attempt <= FIX_ATTEMPTS; attempt++) {
    const tag = `${cl.tag}#${attempt}`
    const f = await agent(fixPrompt(cl, attempt, last), { label: `fix${attempt}:${tag}`, phase: 'Fix', schema: FIX, isolation: 'worktree' })
    if (!f) return { ok: false, why: `fix attempt ${attempt}: fixer failed`, last }
    if (f.held) return { ok: false, held: f.held }
    if (f.gave_up) return { ok: false, why: `fixer: ${f.gave_up}`, last: f }
    if (!SHA40.test(f.base_sha) || !SHA40.test(f.head_sha)) { last = { cause: f.cause, problem: 'base_sha and head_sha must be full 40-hex SHAs' }; continue }
    const rv = await reviewed(cl, f, ['correctness', 'principled'], tag, 'Fix')
    if (rv.held) return { ok: false, held: rv.held }
    if (rv.findings.length) { last = { review_findings: rv.findings }; continue }
    const v = await agent(verifyPrompt(cl, rv.f), { label: `verify${attempt}:${tag}`, phase: 'Verify', schema: VERIFY })
    if (v && v.verdict === 'held') return { ok: false, held: 'verify: the take was refused' }
    if (v && v.verdict === 'improved' && !v.other_regressions.length) return { ok: true, fix: rv.f, verify: v }
    last = { cause: rv.f.cause, head_sha: rv.f.head_sha, verify: v }
  }
  return { ok: false, why: `no verified fix in ${FIX_ATTEMPTS} attempts`, last }
}

function prOutcome(pr, ok) { return !pr ? 'pr-failed' : pr.held ? 'held' : pr.state_set ? ok : 'pr-incomplete' }

async function act(cl) {
  if (cl.route === 'flag-off') {
    const f = await agent(flagOffPrompt(cl), { label: `flag-off:${cl.tag}`, phase: 'Flag off', schema: BRANCH, isolation: 'worktree' })
    if (!f) return { outcome: 'flag-off-failed', note: 'flag-off agent failed' }
    if (f.held) return { outcome: 'held', note: f.held }
    if (!SHA40.test(f.base_sha) || !SHA40.test(f.head_sha)) return { outcome: 'flag-off-failed', note: 'base_sha and head_sha must be full 40-hex SHAs', branch: f }
    const rv = await reviewed(cl, f, ['flag-off'], cl.tag, 'Flag off')
    if (rv.held) return { outcome: 'held', note: rv.held }
    if (rv.findings.length) return { outcome: 'flag-off-review-failed', note: `no SHIP after ${REVIEW_ROUNDS} rounds; the next pass continues ${rv.f.branch}`, findings: rv.findings }
    const pr = await agent(prPrompt(cl, rv.f, `${REASON.flagOff} ${cl.feature}`, flagOffBody(cl)), { label: `pr:${cl.tag}`, phase: 'Flag off', schema: PR })
    // flag-off itself waits for a later pass: the PR merged and the series recovered.
    return { outcome: prOutcome(pr, 'flag-off-pr'), pr, note: pr ? pr.note : 'pr agent failed' }
  }
  const fx = await fixLoop(cl)
  if (fx.held) return { outcome: 'held', note: fx.held }
  if (fx.ok) {
    const pr = await agent(prPrompt(cl, fx.fix, REASON.fix, fixBody(cl, fx.fix, fx.verify)), { label: `pr:${cl.tag}`, phase: 'Verify', schema: PR })
    return { outcome: prOutcome(pr, 'assigned'), fix: fx.fix, verify: fx.verify, pr, note: pr ? pr.note : 'pr agent failed' }
  }
  const rv = await agent(revertPrompt(cl, fx.why), { label: `revert:${cl.tag}`, phase: 'Verify', schema: REVERTED })
  return { outcome: rv ? `no-fix:${rv.action}` : 'no-fix', why: fx.why, last: fx.last, revert: rv, note: fx.why }
}

async function followup(fu) {
  const r = await agent(followupPrompt(fu), { label: `followup:${fu.pr}`, phase: 'Follow up', schema: FOLLOWED })
  return { ...fu, outcome: r ? `follow-up:${r.action}` : 'follow-up-failed', result: r }
}

const followed = pipeline(follow, followup)
// Barrier: groups that share a culprit get one action, so the routes of the whole queue are needed first.
const routed = await pipeline(queue, triage, culprit)
const clusters = culpritClusters(routed)
for (const cl of clusters) if (cl.groups.length > 1) log(`culprit ${short(cl.culprit_sha)} (${cl.route}${cl.feature ? ' ' + cl.feature : ''}): one change for groups ${ids(cl.groups)}`)
const acted = await pipeline(clusters, act)
const byGroup = new Map()
clusters.forEach((cl, i) => { for (const g of cl.groups) byGroup.set(g.id, acted[i] || { outcome: 'failed' }) })
const summary = queue.map((g, i) => {
  const r = byGroup.get(g.id) || routed[i]
  const pr = r && r.pr ? r.pr.pr_url : (r && r.revert ? r.revert.pr_url : '')
  return { group: g.id, outcome: r ? r.outcome : 'failed', pr, note: r ? (r.note || r.why || '') : '' }
})
for (const f of await followed) {
  for (const g of f.groups) summary.push({ group: g.id, outcome: f.outcome, pr: f.pr_url, note: f.result ? f.result.note : '' })
}
for (const s of summary) log(`${s.group}: ${s.outcome}${s.pr ? ' ' + s.pr : ''}`)
return { groups: queue.length, summary, results: { routed, clusters: clusters.map((cl, i) => ({ groups: cl.groups.map(g => g.id), route: cl.route, feature: cl.feature, result: acted[i] })) } }
