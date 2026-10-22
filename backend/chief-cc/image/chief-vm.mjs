// chief-vm: the Cloud Chief's own sandbox VMs (apps/api/src/chief-brain-cc/sandbox.ts), through this turn's
// runner on 127.0.0.1:4018 (run.mjs). They outlive the turn (12 h, paused when idle; at most two).
//
//   chief-vm list
//   chief-vm create
//   chief-vm exec ID [--timeout SECONDS] -- COMMAND...   (runs as root through bash -lc; prints stdout and stderr, exits with its code)
//   chief-vm delete ID
const USAGE = `usage: chief-vm list | create | exec ID [--timeout S] -- COMMAND... | delete ID`
const fail = (msg, code = 1) => [console.error(`chief-vm: ${msg}`), process.exit(code)]
const call = async (body) => {
  const r = await fetch("http://127.0.0.1:4018/vm", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body), signal: AbortSignal.timeout(340_000) }).catch(() => null)
  if (!r) fail("no turn is running on this machine (127.0.0.1:4018 does not answer)")
  const j = await r.json().catch(() => ({}))
  if (!r.ok) fail(j.error ?? `HTTP ${r.status}`)
  return j
}
const q = (a) => (/^[A-Za-z0-9_./=:@%+,-]+$/.test(a) ? a : `'${a.replace(/'/g, `'\\''`)}'`)
const [verb, ...rest] = process.argv.slice(2)
if (verb === "list" || verb === undefined) {
  const j = await call({ action: "list" })
  if (j.vms.length === 0) console.log(`no sandboxes (at most ${j.max}; chief-vm create)`)
  for (const v of j.vms) console.log(`${v.id}\t${v.state}\t${v.name}\tmade ${new Date(v.created_at).toISOString()}`)
} else if (verb === "create") {
  const j = await call({ action: "create" })
  console.log(`${j.vm.id}\t${j.vm.name}\t(${j.ttl_seconds / 3600} h, pauses after ${j.idle_pause_seconds / 60} min idle)`)
} else if (verb === "delete") {
  if (!rest[0]) fail(USAGE, 2)
  console.log(`deleted ${(await call({ action: "delete", id: rest[0] })).deleted}`)
} else if (verb === "exec") {
  const [id, ...args] = rest
  let timeout = 120
  let i = 0
  for (; i < args.length && args[i] !== "--"; i++) if (args[i] === "--timeout") timeout = Number(args[++i]) || 120
  const cmd = args.slice(i + 1)
  if (!id || cmd.length === 0) fail(USAGE, 2)
  const line = cmd.length === 1 ? cmd[0] : cmd.map(q).join(" ")
  const j = await call({ action: "exec", id, command: `bash -lc ${q(line)} 2>&1`, timeout_ms: timeout * 1000 })
  process.stdout.write(j.stdout ?? "")
  process.exit(typeof j.exit === "number" ? j.exit : 1)
} else fail(USAGE, 2)
