// chief-vm: the Cloud Chief's own sandbox VMs (apps/api/src/chief-brain-cc/sandbox.ts), through this turn's
// runner on 127.0.0.1:4018 (run.mjs). They outlive the turn (12 h by default, paused when idle; at most your cap).
// Only VMs you made are reachable; the Freestyle key never leaves the Worker. Parity plan:
// plans/cmux-next/chief-vm-freestyle-parity.md.
//
//   chief-vm list                                   (state, size, cost per hour)
//   chief-vm get ID
//   chief-vm cap                                    (your cap, how many are live, the plan's per-VM maximums)
//   chief-vm create [SIZE] [SETTINGS] [--image ubuntu|chief] [--snapshot freestyle/NAME]
//                                                   (default: Ubuntu 24.04 on a 16 GB disk, 4 vCPU / 8 GiB;
//                                                    --image chief: your machine image with its tools, 32 GB)
//   chief-vm update ID SETTINGS
//   chief-vm resize ID SIZE                         (grow only; CPU and memory live, then the disk and its filesystem)
//   chief-vm pause ID | start ID | stop ID          (pause keeps memory; stop powers off, the disk stays)
//   chief-vm exec ID [--timeout S] [--user root|chief] [--env K=V]... [--stdin FILE|-] -- COMMAND...
//                                                   (bash -lc; prints stdout and stderr, exits with its code)
//   chief-vm fs ls|stat|exists|mkdir|rm ID PATH     (reads work while paused, without waking it)
//   chief-vm fs cat ID PATH                         (prints the file)
//   chief-vm fs put ID LOCAL REMOTE                 (any size: chunked, resumable upload, sha256-checked)
//   chief-vm fs get ID REMOTE LOCAL                 (any size: ranged reads)
//   chief-vm snapshot ID [--name TEXT] [--ttl-seconds N]   (memory and disk; kept 7 days by default)
//   chief-vm snapshots | snapshot-get SNAP | snapshot-rename SNAP NAME | snapshot-delete SNAP
//   chief-vm fork ID [SIZE] [SETTINGS]              (a snapshot, then a new sandbox from it)
//   chief-vm create --snapshot SNAP                 (start from one of your snapshots)
//   chief-vm delete ID
//
//   SIZE: --cpu N --memory-gb N --disk-gb N (grow only; the disk starts at the image's size)
//   SETTINGS: --name TEXT --meta K=V (repeatable) --idle-seconds N --ttl-seconds N
import { createHash } from "node:crypto"
import { closeSync, openSync, readFileSync, readSync, statSync, writeSync } from "node:fs"

const USAGE = `usage: chief-vm list | get ID | cap | create [SIZE] [SETTINGS] [--image ubuntu|chief] [--snapshot freestyle/NAME] | update ID SETTINGS | resize ID SIZE | pause ID | start ID | stop ID | exec ID [--timeout S] [--user root|chief] [--env K=V]... [--stdin FILE|-] -- COMMAND... | fs ls|stat|exists|mkdir|rm|cat ID PATH | fs put ID LOCAL REMOTE | fs get ID REMOTE LOCAL | snapshot ID [--name T] [--ttl-seconds N] | snapshots | snapshot-get SNAP | snapshot-rename SNAP NAME | snapshot-delete SNAP | fork ID [SIZE] [SETTINGS] | delete ID
  SIZE: --cpu N --memory-gb N --disk-gb N    SETTINGS: --name TEXT --meta K=V --idle-seconds N --ttl-seconds N`
const fail = (msg, code = 1) => [console.error(`chief-vm: ${msg}`), process.exit(code)]
const call = async (body) => {
  const r = await fetch("http://127.0.0.1:4018/vm", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body), signal: AbortSignal.timeout(340_000) }).catch(() => null)
  if (!r) fail("no turn is running on this machine (127.0.0.1:4018 does not answer)")
  const j = await r.json().catch(() => ({}))
  if (!r.ok) fail(j.error ?? `HTTP ${r.status}`)
  return j
}
const q = (a) => (/^[A-Za-z0-9_./=:@%+,-]+$/.test(a) ? a : `'${a.replace(/'/g, `'\\''`)}'`)
const whole = (v) => {
  const n = Number(v)
  return Number.isInteger(n) && n >= 1 ? n : fail(USAGE, 2)
}
// SIZE and SETTINGS flags (and --snapshot where `create` allows it); anything else is a usage error.
const flags = (args, allow) => {
  const out = {}
  for (let i = 0; i < args.length; i++) {
    const f = args[i]
    const v = args[i + 1]
    if (v === undefined) fail(USAGE, 2)
    if (allow.size && f === "--cpu") out.cpu = whole(v)
    else if (allow.size && f === "--memory-gb") out.memory_mb = whole(v) * 1024
    else if (allow.size && f === "--disk-gb") out.disk_gb = whole(v)
    else if (allow.settings && f === "--name") out.name = v
    else if (allow.settings && f === "--meta") {
      const at = v.indexOf("=")
      if (at < 1) fail(USAGE, 2)
      out.metadata = { ...(out.metadata ?? {}), [v.slice(0, at)]: v.slice(at + 1) }
    } else if (allow.settings && f === "--idle-seconds") out.idle_seconds = whole(v)
    else if (allow.settings && f === "--ttl-seconds") out.ttl_seconds = whole(v)
    else if (allow.snapshot && f === "--snapshot") out.snapshot = v
    else if (allow.snapshot && f === "--image") out.image = v
    else fail(USAGE, 2)
    i++
  }
  return out
}
const size = (r) => (r ? `${r.cpu} vCPU, ${r.memory_mb / 1024} GiB, ${r.disk_gb} GB disk` : "size unknown")
const cost = (c) => (c ? `$${c.running_usd_per_hour.toFixed(4)}/h running, $${c.paused_usd_per_hour.toFixed(4)}/h paused` : "cost unknown")
const line = (v) => `${v.id}\t${v.state}\t${v.display_name ?? v.name}\t${size(v.resources)}\t${cost(v.cost)}`
const idOf = (rest) => (rest[0] && !rest[0].startsWith("--") ? rest[0] : fail(USAGE, 2))

const [verb, ...rest] = process.argv.slice(2)
if (verb === "list" || verb === undefined) {
  const j = await call({ action: "list" })
  if (j.vms.length === 0) console.log(`no sandboxes (at most ${j.max}; chief-vm create)`)
  for (const v of j.vms) console.log(line(v))
} else if (verb === "get") {
  const v = (await call({ action: "get", id: idOf(rest) })).vm
  console.log(line(v))
  console.log(`made ${new Date(v.created_at).toISOString()}; pauses after ${v.idle_timeout_seconds ?? "?"} s idle; deleted ${v.ttl_seconds ?? "?"} s after it was made`)
  if (v.metadata && Object.keys(v.metadata).length) console.log(`metadata: ${JSON.stringify(v.metadata)}`)
} else if (verb === "cap") {
  const j = await call({ action: "cap" })
  console.log(`${j.live} of ${j.cap} sandboxes live; Freestyle ${j.plan.name} plan: at most ${size(j.plan.max)} per VM`)
} else if (verb === "create") {
  const j = await call({ action: "create", ...flags(rest, { size: true, settings: true, snapshot: true }) })
  console.log(`${j.vm.id}\t${j.vm.name}\t(${j.ttl_seconds / 3600} h, pauses after ${j.idle_pause_seconds / 60} min idle)`)
  console.log(`size: ${size(j.resources)}; ${cost(j.cost)}${j.df ? `\ndf: ${j.df}` : ""}`)
  if (j.resize_error) console.error(`chief-vm: made, but not resized: ${j.resize_error}`)
} else if (verb === "update") {
  const want = flags(rest.slice(1), { settings: true })
  if (Object.keys(want).length === 0) fail(USAGE, 2)
  console.log(line((await call({ action: "update", id: idOf(rest), ...want })).vm))
} else if (verb === "resize") {
  const want = flags(rest.slice(1), { size: true })
  if (Object.keys(want).length === 0) fail(USAGE, 2)
  const j = await call({ action: "resize", id: idOf(rest), ...want })
  console.log(`${j.id}\t${size(j.resources)}\t${cost(j.cost)}`)
  if (j.guest) console.log(`guest sees: ${j.guest.nproc} CPUs, ${j.guest.memory_mb} MiB memory; ${j.guest.df}`)
  else if (j.df) console.log(`df: ${j.df}`)
} else if (verb === "pause" || verb === "start" || verb === "stop") {
  const j = await call({ action: verb, id: idOf(rest) })
  console.log(`${j.id}\t${j.state}\t${cost(j.cost)}`)
} else if (verb === "delete") {
  console.log(`deleted ${(await call({ action: "delete", id: idOf(rest) })).deleted}`)
} else if (verb === "exec") {
  const [id, ...args] = rest
  const req = { action: "exec", id, timeout_ms: 120_000 }
  let i = 0
  for (; i < args.length && args[i] !== "--"; i++) {
    const v = args[i + 1]
    if (v === undefined) fail(USAGE, 2)
    if (args[i] === "--timeout") req.timeout_ms = whole(v) * 1000
    else if (args[i] === "--user") req.user = v
    else if (args[i] === "--env") {
      const at = v.indexOf("=")
      if (at < 1) fail(USAGE, 2)
      req.env = { ...(req.env ?? {}), [v.slice(0, at)]: v.slice(at + 1) }
    } else if (args[i] === "--stdin") req.stdin = readFileSync(v === "-" ? 0 : v).toString("base64")
    else fail(USAGE, 2)
    i++
  }
  const cmd = args.slice(i + 1)
  if (!id || cmd.length === 0) fail(USAGE, 2)
  const text = cmd.length === 1 ? cmd[0] : cmd.map(q).join(" ")
  const j = await call({ ...req, command: `bash -lc ${q(text)}` })
  process.stdout.write(j.stdout ?? "")
  process.stderr.write(j.stderr ?? "")
  process.exit(typeof j.exit === "number" ? j.exit : 1)
} else if (verb === "fs") {
  const [op, id, a, b2] = rest
  if (!op || !id || !a) fail(USAGE, 2)
  const fsc = (o, more) => call({ action: "fs", id, op: o, ...more })
  if (["ls", "stat", "exists", "mkdir", "rm"].includes(op)) {
    const j = await fsc(op, { path: a })
    if (op === "ls") for (const e of j.entries ?? []) console.log(`${e.kind === "directory" ? `${e.name}/` : e.name}`)
    else if (op === "exists") [console.log(j.exists ? "yes" : "no"), process.exit(j.exists ? 0 : 1)]
    else if (op === "stat") console.log(JSON.stringify(j))
    else console.log(`${op === "rm" ? "removed" : "made"} ${a}`)
  } else if (op === "cat" || op === "get") {
    if (op === "get" && !b2) fail(USAGE, 2)
    const fd = op === "get" ? openSync(b2, "w") : 1
    let offset = 0
    for (;;) {
      const j = await fsc("read", { path: a, offset })
      const bytes = Buffer.from(j.data ?? "", "base64")
      if (bytes.length) writeSync(fd, bytes)
      offset += bytes.length
      if (j.eof || bytes.length === 0) break
    }
    if (op === "get") [closeSync(fd), console.log(`${a} -> ${b2} (${offset} bytes)`)]
  } else if (op === "put") {
    if (!b2) fail(USAGE, 2)
    const size = statSync(a).size
    const sha256 = createHash("sha256").update(readFileSync(a)).digest("hex")
    const begun = await fsc("upload_begin", { path: b2, size, sha256 })
    const upload_id = begun.upload?.uploadId ?? begun.upload?.id
    const chunk = begun.chunk ?? 131072
    const fd = openSync(a, "r")
    const buf = Buffer.alloc(chunk)
    for (let offset = 0; offset < size; ) {
      const n = readSync(fd, buf, 0, chunk, offset)
      await fsc("upload_chunk", { upload_id, offset, data: buf.subarray(0, n).toString("base64") })
      offset += n
    }
    closeSync(fd)
    await fsc("upload_commit", { upload_id })
    console.log(`${a} -> ${b2} (${size} bytes, sha256 ${sha256.slice(0, 12)})`)
  } else fail(USAGE, 2)
} else if (verb === "snapshot") {
  const want = flags(rest.slice(1), { settings: true })
  const j = await call({ action: "snapshot", id: idOf(rest), ...(want.name ? { name: want.name } : {}), ...(want.ttl_seconds ? { ttl_seconds: want.ttl_seconds } : {}) })
  console.log(`${j.snapshot.id}\t${j.snapshot.name ?? ""}\tof ${j.snapshot.source}, kept ${Math.round(j.snapshot.ttl_seconds / 86400)} d`)
} else if (verb === "snapshots") {
  const j = await call({ action: "snapshots" })
  if (j.snapshots.length === 0) console.log("no snapshots (chief-vm snapshot ID)")
  for (const x of j.snapshots) console.log(`${x.id}\t${x.display_name ?? ""}\tof ${x.source}\tmade ${new Date(x.created_at).toISOString()}`)
} else if (verb === "snapshot-get" || verb === "snapshot-delete") {
  const j = await call({ action: verb.replace("-", "_"), snapshot: idOf(rest) })
  console.log(verb === "snapshot-get" ? JSON.stringify(j.snapshot) : `deleted ${j.deleted}`)
} else if (verb === "snapshot-rename") {
  if (!rest[1]) fail(USAGE, 2)
  console.log(JSON.stringify((await call({ action: "snapshot_rename", snapshot: idOf(rest), name: rest[1] })).snapshot))
} else if (verb === "fork") {
  const j = await call({ action: "fork", id: idOf(rest), ...flags(rest.slice(1), { size: true, settings: true }) })
  console.log(`${j.vm.id}\t${j.vm.name}\tforked from ${j.forked_from} (snapshot ${j.snapshot})`)
  console.log(`size: ${size(j.resources)}; ${cost(j.cost)}`)
} else fail(USAGE, 2)
