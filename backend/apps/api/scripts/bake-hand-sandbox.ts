// Bakes the Chief hand sandbox image (HAND_SANDBOX_SNAPSHOT) on Freestyle, from Freestyle's base
// image, owned by the hands lane (it depends on no other lane's snapshot):
//   FREESTYLE_KEY_FILE=~/.secrets/freestyle-cmux-next-dev-20261004.key bun scripts/bake-hand-sandbox.ts cmuxnp-stg-hand-v3 <release tree>
// It makes one VM, installs Node 24, git, curl, Claude Code and OpenCode, runs OpenCode once (its first
// run sets up its store), makes the default work folder /root/proj, puts the published hand of
// <release tree> (the deployment's HAND_RELEASE_TREE; its sha256 from the tree's completion.json) at
// /usr/local/lib/cmux-hand/cmux-hand, which install.sh uses only while it is exactly the published
// file (a sandbox then skips the download and only pairs), checks the tools, snapshots the VM under the slug, and deletes the VM by its
// exact id (also when a step fails). The slug is the image name to set as HAND_SANDBOX_SNAPSHOT.
// Rebake: run it again with the next slug (cmuxnp-stg-hand-v2, ...), set the var, keep the old slug
// until no hand sandbox uses it. The key file is read here and never printed.
import { readFileSync } from "node:fs"
import { homedir } from "node:os"

const slug = process.argv[2] ?? ""
if (!/^cmuxnp-(dev|stg)-hand-v[0-9]+$/.test(slug)) throw new Error("usage: bake-hand-sandbox.ts cmuxnp-<dev|stg>-hand-v<N> <release tree>")
const tree = process.argv[3] ?? ""
if (!/^[0-9a-f]{40}$/.test(tree)) throw new Error("usage: bake-hand-sandbox.ts cmuxnp-<dev|stg>-hand-v<N> <release tree (40 hex)>")
const release = `https://files.cmux.com/cmux-tui/tree/${tree}`
const completion = (await (await fetch(`${release}/completion.json`)).json()) as { binaries?: Record<string, string> }
const handSha = completion.binaries?.["cmux-tui-acpmux-x86_64-unknown-linux-musl"] ?? ""
if (!/^[0-9a-f]{64}$/.test(handSha)) throw new Error(`no x86_64 linux hand in tree ${tree}`)
const keyFile = (process.env.FREESTYLE_KEY_FILE ?? "~/.secrets/freestyle-cmux-next-dev-20261004.key").replace(/^~/, homedir())
const key = readFileSync(keyFile, "utf8").trim()
const API = "https://api.freestyle.sh"
const call = async (method: string, path: string, body?: unknown, ms = 60_000) => {
  const res = await fetch(`${API}${path}`, { method, redirect: "manual", headers: { authorization: `Bearer ${key}`, "content-type": "application/json" }, ...(body === undefined ? {} : { body: JSON.stringify(body) }), signal: AbortSignal.timeout(ms) })
  return { status: res.status, json: (await res.json().catch(() => ({}))) as Record<string, any> }
}
const STEPS: Array<[string, string]> = [
  ["apt", "export DEBIAN_FRONTEND=noninteractive && apt-get update -qq && apt-get install -y -qq ca-certificates curl git xz-utils python3 >/dev/null"],
  ["node", "set -e; ver=$(curl -fsSL https://nodejs.org/dist/latest-v24.x/ | grep -o 'node-v[0-9.]*-linux-x64.tar.xz' | head -1); curl -fsSL https://nodejs.org/dist/latest-v24.x/$ver -o /tmp/node.tar.xz; mkdir -p /opt/node && tar -xJf /tmp/node.tar.xz -C /opt/node --strip-components 1 && rm /tmp/node.tar.xz; for b in node npm npx; do ln -sf /opt/node/bin/$b /usr/local/bin/$b; done; node --version"],
  ["agents", "set -e; npm install -g --no-fund --no-audit @anthropic-ai/claude-code opencode-ai >/dev/null; for b in claude opencode; do ln -sf /opt/node/bin/$b /usr/local/bin/$b; done"],
  // The base image's login shell puts an older nvm Node (with its own old claude) first on PATH:
  // remove those copies, so every shell finds the ones above.
  ["old agents", "for d in /usr/local/nvm/versions/node/*/bin; do rm -f \"$d/claude\" \"$d/opencode\"; done; true"],
  ["work folder", "mkdir -p /root/proj"],
  ["hand", `set -e; mkdir -p /usr/local/lib/cmux-hand; curl -fsSL ${release}/cmux-tui-acpmux-x86_64-unknown-linux-musl -o /usr/local/lib/cmux-hand/cmux-hand.tmp; test "$(sha256sum /usr/local/lib/cmux-hand/cmux-hand.tmp | cut -d' ' -f1)" = ${handSha}; chmod 755 /usr/local/lib/cmux-hand/cmux-hand.tmp; mv /usr/local/lib/cmux-hand/cmux-hand.tmp /usr/local/lib/cmux-hand/cmux-hand`],
  ["opencode first run", "timeout 120 opencode models >/dev/null 2>&1; echo rc=$?"],
  ["record", `printf 'image=${slug}\\nbaked_at=%s\\nnode=%s\\nclaude=%s\\nopencode=%s\\nhand_tree=${tree}\\n' "$(date -u +%FT%TZ)" "$(node --version)" "$(claude --version | head -1)" "$(opencode --version)" > /etc/cmux-hand-image; rm -f /root/.bash_history; cat /etc/cmux-hand-image`],
  ["verify", "set -e; command -v curl git node claude opencode; test \"$(bash -lc 'command -v claude')\" = /usr/local/bin/claude; test \"$(bash -lc 'command -v opencode')\" = /usr/local/bin/opencode; bash -lc 'claude --version'"]
]
const created = await call("POST", "/v5/vms", { idleTimeoutSeconds: 900, automaticRestart: false, firewall: { rules: [{ action: "allow", source: {}, destination: { public: true } }] }, metadata: { purpose: "hand-sandbox-bake", image: slug } })
const vm = (created.json.vmId ?? created.json.id) as string | undefined
if (!vm) throw new Error(`create: ${created.status}`)
console.log(`bake vm ${vm}`)
let ok = false
try {
  for (const [name, command] of STEPS) {
    const t0 = Date.now()
    const r = await call("POST", `/v5/vms/${vm}/exec-await`, { command: `echo ${Buffer.from(command).toString("base64")} | base64 -d | bash`, timeoutMs: 290_000, linuxUser: "root" }, 300_000)
    const out = `${r.json.stdout ?? ""}${r.json.stderr ?? ""}`.trim().slice(-800)
    if (r.status !== 200 || r.json.statusCode !== 0) throw new Error(`${name} failed (${r.status}, exit ${r.json.statusCode}): ${out}`)
    console.log(`ok ${name} ${((Date.now() - t0) / 1000).toFixed(1)}s${name === "record" || name === "verify" ? `\n${out}` : ""}`)
  }
  const snap = await call("POST", `/v5/vms/${vm}/snapshot`, { slug }, 600_000)
  if (snap.status < 200 || snap.status >= 300) throw new Error(`snapshot: ${snap.status} ${JSON.stringify(snap.json).slice(0, 300)}`)
  console.log(`snapshot ${slug} ${snap.json.snapshotId}`)
  ok = true
} finally {
  const d = await call("DELETE", `/v5/vms/${vm}`)
  console.log(`vm ${vm} ${d.status === 200 || d.status === 404 ? "deleted" : `delete answered ${d.status}`}${ok ? "" : " (bake failed)"}`)
}
