// chief-net: shows or changes what this Cloud Chief machine's agent user may reach on the network (chief-turn-runner
// serves it on 127.0.0.1:4018 during a turn; the Worker keeps a change for the Chief's next turns).
//
//   chief-net [show]
//   chief-net set internet=on|off dns=on|off tailnet=on|off local=on|off
//   chief-net allow|deny|unallow|undeny HOST-OR-RANGE...
//   chief-net reset
const USAGE = `usage: chief-net [show]
       chief-net set internet=on|off dns=on|off tailnet=on|off local=on|off
       chief-net allow|deny|unallow|undeny HOST-OR-RANGE...
       chief-net reset
internet: every public IPv4 and IPv6 address    dns: lookups through /etc/resolv.conf
tailnet:  this machine's tailnet node           local: every loopback port
allow: reachable even with internet off         deny: never reachable`
const fail = (msg) => [console.error(`chief-net: ${msg}`), process.exit(1)]
const call = async (method, body) => {
  const r = await fetch("http://127.0.0.1:4018/net", { method, headers: { "content-type": "application/json" }, ...(body ? { body: JSON.stringify(body) } : {}), signal: AbortSignal.timeout(60_000) }).catch(() => null)
  if (!r) fail("no turn is running on this machine (127.0.0.1:4018 does not answer)")
  const j = await r.json().catch(() => ({}))
  if (!r.ok) fail(j.error ?? `HTTP ${r.status}`)
  return j
}
const [cmd = "show", ...args] = process.argv.slice(2)
const ON = { on: true, true: true, yes: true, 1: true, off: false, false: false, no: false, 0: false }
let out
if (cmd === "show") out = await call("GET")
else if (cmd === "reset") out = await call("PUT", { reset: true })
else if (cmd === "set") {
  if (args.length === 0) fail(USAGE)
  const patch = {}
  for (const a of args) {
    const [k, v] = a.split("=")
    if (!k || v === undefined || !(v.toLowerCase() in ON)) fail(`${a}: expected NAME=on|off\n${USAGE}`)
    patch[k] = ON[v.toLowerCase()]
  }
  out = await call("PUT", patch)
} else if (["allow", "deny", "unallow", "undeny"].includes(cmd)) {
  if (args.length === 0) fail(USAGE)
  const list = cmd.endsWith("allow") ? "allow" : "deny"
  const now = (await call("GET")).net?.[list] ?? []
  const next = cmd.startsWith("un") ? now.filter((e) => !args.map((a) => a.toLowerCase()).includes(e)) : [...now, ...args]
  out = await call("PUT", { [list]: next })
} else fail(USAGE)
console.log(JSON.stringify(out, null, 2))
