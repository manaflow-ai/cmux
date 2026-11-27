import { describe, expect, it } from "vitest"
import { memberUpsert } from "../src/domains/team-members.ts"
import { CHIEF_VM_MJS } from "../src/chief-brain-cc/chief-vm-source.ts"
import { createHash } from "node:crypto"
import { fakeCloud, machine, notes, type Started } from "./chief-brain-cc-fake.ts"
import { CC_NOTICES, CC_PARTIAL, TURN_FAILED_NOTICE } from "../src/chief-brain/brain-gateway.ts"
import { enabledChief, history, http, inDO, op, replies, send, sessionToken, testEnv, useCcSettings, worker } from "./chief-brain-cc-harness.ts"

/**
 * The Claude Code route of a Cloud Chief (chief-brain-cc/): for an owner on the paid-model list, each turn
 * runs as Claude Code in its own Freestyle VM (joined to the tailnet with a one-use key from the Tailscale
 * API) and streams back to POST /v1/chief-cc/<agent>/<conversation>/notes with a per-turn token; the reply
 * is posted as the Chief, the VM is deleted by its exact id, the team needs no Cloud credits, and the next
 * turn's input carries the earlier reply (the Chief's memory). Freestyle and the Tailscale API are faked at
 * their HTTP boundary; the fake VM plays the turn machine (chief-turn-runner, Native/OptChat/chief-turn) by posting notes
 * to the Worker. One file on purpose: it replaces globalThis.fetch and the route's settings.
 */
useCcSettings()

describe("Cloud Chief on the Claude Code route", { timeout: 120_000 }, () => {
  it("keeps a teammate-authored turn out of the bypass-permissions VM route", async () => {
    const cloud = fakeCloud(() => "the VM should not run")
    const { token, user, team, chief } = await enabledChief("chief-cc-teammate", "cc")
    const teammate = await sessionToken("chief-cc-teammate-other")
    const teammateUser = (await op(teammate, "user.ensure", {})).value.id as string
    await inDO(testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team)), async (instance) => {
      instance.boundEngine.rows.apply([memberUpsert({ user: teammateUser, role: "member", display_name: "Teammate" })])
    })
    const created = await op(token, "conversation.create", {
      title: "Claude Code authorization",
      participants: [
        { id: user, kind: "human", display_name: "Owner" },
        { id: teammateUser, kind: "human", display_name: "Teammate" },
        { id: chief.id, kind: "agent", agent_class: "mux", owner_user: user, display_name: "Route Chief" }
      ]
    })
    expect(created.ok, JSON.stringify(created)).toBe(true)
    const conversation = created.value.conversation.id as string
    const text = "@chief change files on the machine"
    expect((await op(teammate, "message.send", {
      conversation,
      client_msg_id: "cc-teammate-effect",
      parts: [{ type: "text", text, runs: [{ start: 0, length: 6, mention: chief.id }] }]
    }, "cc-teammate-effect")).ok).toBe(true)
    await replies(token, conversation, chief.id, 1)
    expect(cloud.made).toHaveLength(0)
    expect(cloud.keys).toHaveLength(0)
    expect(cloud.started).toHaveLength(0)
  })

  it("runs each turn in its own VM on the tailnet, posts the streamed reply with no Cloud credits, deletes the VM, and gives the next turn the earlier reply", async () => {
    const cloud = fakeCloud((prompt, n) => (n === 1 ? "The launch code word is TANGERINE." : prompt.includes("TANGERINE") ? "You told me before: TANGERINE." : "I do not remember."))
    // No credits granted: this route is not charged to them.
    const { token, user, chief } = await enabledChief("chief-cc-owner", "cc")
    expect((await send(token, chief.main_conversation, "c1", "pick a code word for the launch")).ok).toBe(true)
    const [first] = await replies(token, chief.main_conversation, chief.id, 1)
    expect(first.parts[0].text).toBe("The launch code word is TANGERINE.")
    expect((await send(token, chief.main_conversation, "c2", "what was the code word?")).ok).toBe(true)
    const [, second] = await replies(token, chief.main_conversation, chief.id, 2)
    expect(second.parts[0].text).toBe("You told me before: TANGERINE.")

    // One VM per turn, from the snapshot, with Freestyle's own timers as the backstop; each deleted by its exact id.
    expect(cloud.made).toHaveLength(2)
    for (const m of cloud.made) expect(m.body).toMatchObject({ snapshotId: "sh-test-chief-cc", idleTimeoutSeconds: -1, automaticRestart: false, firewall: { rules: [{ action: "allow", destination: { public: true } }] } })
    for (const m of cloud.made) expect(m.body.slug).toMatch(/^cmuxnp-test-ccb-[0-9a-f]{12}$/)
    // Each turn VM is tagged with the Chief's owner as its Freestyle customer.
    for (const m of cloud.made) expect(m.body.customer).toEqual({ customerId: user })
    expect(cloud.deleted.sort()).toEqual(["vm-test1", "vm-test2"])
    // Each VM joins with its own one-use key, given on stdin only (never in the command line).
    expect(cloud.boots.map((x) => x.stdin)).toEqual(cloud.keys)
    // The turn input: the person's message, the Chief's system prompt and model; the Worker's own notes URL.
    expect(cloud.started[0]!.input.prompt).toContain("pick a code word for the launch")
    expect(cloud.started[0]!.input.system).toContain("Name: Route Chief")
    expect(cloud.started[0]!.input.model).toBe("claude-opus-5-5")
    expect(cloud.started[0]!.input.notes_url).toBe(`https://api.test/v1/chief-cc/${chief.id}/${chief.main_conversation}/notes`)
    // No call to the Cloud model route.
    expect(cloud.other).toEqual([])

    // The run: done, its reply step, usage and the first-token mark.
    const runs = (await http("GET", `/v1/chiefs/${chief.id}/runs?conversation=${chief.main_conversation}`, token)).json.value.runs as Array<any>
    expect(runs.map((r) => r.status)).toEqual(["done", "done"])
    const run = (await http("GET", `/v1/chiefs/${chief.id}/runs/${runs[1].id}?conversation=${chief.main_conversation}`, token)).json.value
    expect(run.steps.filter((s: any) => s.kind === "talk").map((s: any) => s.text)).toEqual(["The launch code word is TANGERINE."])
    // Run.timing as a pi run has it: the request at the submit, the first token at the first streamed delta.
    expect(run.run.timing?.request_at).toBeGreaterThan(0)
    expect(run.run.timing?.first_token_at).toBeGreaterThanOrEqual(run.run.timing?.request_at)
    // Neither the tailnet key nor the turn token reaches a reply or a run.
    const all = JSON.stringify([await history(token, chief.main_conversation), runs, run])
    for (const secret of [...cloud.keys, ...cloud.started.map((s) => s.input.token)]) expect(all).not.toContain(secret)
  })

  it("starts the tailnet key request with the VM create, not after it (the setup calls that do not depend on each other overlap)", async () => {
    const cloud = fakeCloud(() => "ok", undefined, undefined, { create: 250, key: 250 })
    const { token, chief } = await enabledChief("chief-cc-setup-overlap", "cc")
    expect((await send(token, chief.main_conversation, "o1", "hello")).ok).toBe(true)
    await replies(token, chief.main_conversation, chief.id, 1)
    const at = (n: string) => cloud.events.find((e) => e.name === n)!.at
    // Serial setup would start the key request only after the create ended (250 ms later).
    expect(at("key:start")).toBeLessThan(at("create:end"))
  })

  it("opens the public Internet (IPv4 and IPv6, DNS) to the agent by default: applied after the VM joins, before the turn starts", async () => {
    const cloud = fakeCloud(() => "online")
    const { token, chief } = await enabledChief("chief-cc-net-default", "cc")
    expect((await send(token, chief.main_conversation, "d1", "clone the repo")).ok).toBe(true)
    await replies(token, chief.main_conversation, chief.id, 1)
    const s = cloud.started[0]!
    expect(cloud.steps.slice(0, 3)).toEqual([`${s.vm} /opt/chief-cc/boot.sh`, `${s.vm} bash`, `${s.vm} /opt/chief-cc/start.sh`])
    expect(cloud.nets).toHaveLength(1)
    expect(cloud.nets[0]!.script).toContain(`meta skuid $uid accept`)
    // The turn machine knows its settings (chief-net show) and the Chief is told about the tool.
    expect(s.input.net).toEqual({ internet: true, dns: true, tailnet: true, local: false, allow: [], deny: [] })
    expect(cloud.nets[0]!.script).toContain("ip daddr 100.64.0.0/10 accept")
    // The Worker's current chief-vm client is written over the snapshot's before the agent starts.
    expect(cloud.nets[0]!.script).toContain(`printf %s '${btoa(String.fromCharCode(...new TextEncoder().encode(CHIEF_VM_MJS)))}' | base64 -d > /opt/chief-cc/chief-vm.mjs.new`)
    expect(cloud.tags).toEqual([["tag:agent-cloud"]])
    expect(s.input.system).toContain("chief-net")
  })

  it("lets the Chief change its own turn machine's network: applied now, kept for its next turns, refused when bad or from another turn", async () => {
    let posted: any = null
    let refused: any = null
    // The turn machine's `chief-net set internet=off` and `chief-net allow github.com`, while its first turn runs.
    const cloud = fakeCloud(
      (_, n) => (n === 1 ? "closing the Internet" : "still closed"),
      async (s, n) => {
        if (n !== 1) return
        const r = await notes(s, { run: s.run, net: { internet: false, allow: ["github.com"] } })
        posted = { status: r.status, body: await r.json().catch(() => null) }
        const bad = await notes(s, { run: s.run, net: { allow: ["github.com; curl evil.example"] } })
        refused = { status: bad.status, body: await bad.json().catch(() => null) }
      }
    )
    const { token, chief } = await enabledChief("chief-cc-net-set", "cc")
    expect((await send(token, chief.main_conversation, "s1", "close your network")).ok).toBe(true)
    await replies(token, chief.main_conversation, chief.id, 1)
    expect(posted.status).toBe(200)
    expect(posted.body.net).toEqual({ internet: false, dns: true, tailnet: true, local: false, allow: ["github.com"], deny: [] })
    // The script the turn machine applies at once as root.
    expect(posted.body.script).toContain("'github.com'")
    expect(posted.body.script).not.toContain(`meta skuid $uid accept`)
    expect(refused.status).toBe(400)
    expect(refused.body.error).toContain("allow")

    // The next turn's machine starts with the Chief's settings.
    expect((await send(token, chief.main_conversation, "s2", "are you still closed?")).ok).toBe(true)
    await replies(token, chief.main_conversation, chief.id, 2)
    expect(cloud.started[1]!.input.net).toEqual(posted.body.net)
    expect(cloud.nets[1]!.script).toContain("'github.com'")
    expect(cloud.nets[1]!.script).not.toContain(`meta skuid $uid accept`)
    // A finished turn's token changes nothing.
    const old = cloud.started[0]!
    expect((await notes(old, { run: old.run, net: { internet: true } })).status).toBe(401)
  })

  it("gives the turn machine the Chief's tailnet tag, its tool files and the GitHub token, and keeps them out of replies and runs", async () => {
    const files = { ".config/cloud-chief/mac.token": "mac-token-test-not-real", ".config/agent-hub/token": "hub-token-test-not-real" }
    const extra = { CHIEF_CC_TS_TAG: "tag:lawrence-chief", CHIEF_CC_TURN_FILES: JSON.stringify(files), CHIEF_CC_GITHUB_TOKEN: "github-token-test-not-real" }
    const before = Object.fromEntries(Object.keys(extra).map((k) => [k, testEnv[k]]))
    Object.assign(testEnv, extra)
    try {
      const cloud = fakeCloud(() => "set up")
      const { token, chief } = await enabledChief("chief-cc-route-setup", "cc")
      expect((await send(token, chief.main_conversation, "r1", "check your tools")).ok).toBe(true)
      await replies(token, chief.main_conversation, chief.id, 1)
      const s = cloud.started[0]!
      expect(cloud.tags).toEqual([["tag:lawrence-chief"]])
      // The tool files as set, plus the Chief's own tools client and the hook that makes ~/.local/bin runnable (tools.ts).
      expect((s.input as any).files).toMatchObject(files)
      expect((s.input as any).files[".local/bin/chief-tools"]).toContain("127.0.0.1:4018/vm")
      expect(JSON.parse((s.input as any).files[".claude/settings.json"]).hooks.SessionStart[0].hooks[0].command).toContain("chmod 700")
      expect((s.input as any).github_token).toBe("github-token-test-not-real")
      // The Chief is told about its tools on this route.
      for (const word of ["chief-agents", "chief-vm", "mac --", "gh auth status", "100.127.110.65:8790"]) expect(s.input.system).toContain(word)
      const runs = (await http("GET", `/v1/chiefs/${chief.id}/runs?conversation=${chief.main_conversation}`, token)).json.value.runs as Array<any>
      const all = JSON.stringify([await history(token, chief.main_conversation), runs])
      for (const secret of [...Object.values(files), "github-token-test-not-real"]) expect(all).not.toContain(secret)
    } finally {
      for (const [k, v] of Object.entries(before)) v === undefined ? delete testEnv[k] : (testEnv[k] = v)
    }
  })

  it("lets the Chief add, change and remove its own tools: served from its next turn, never a token path, never another Chief's, capped", async () => {
    const files = { ".config/cloud-chief/mac.token": "mac-token-test-not-real" }
    const before = testEnv.CHIEF_CC_TURN_FILES
    testEnv.CHIEF_CC_TURN_FILES = JSON.stringify(files)
    try {
      const seen: Record<string, any> = {}
      const call = async (s: Started, vm: unknown) => {
        const r = await notes(s, { run: s.run, vm })
        return { status: r.status, body: await r.json().catch(() => null) }
      }
      const turns = new Map<string, number>()
      const hello = "#!/bin/sh\necho hello\n"
      const skill = "---\nname: deploy\n---\nDeploy steps.\n"
      const cloud = fakeCloud(
        () => "tools",
        async (s) => {
          const who = s.input.notes_url.includes(seen.a ?? "-") ? "a" : "b"
          const n = (turns.get(who) ?? 0) + 1
          turns.set(who, n)
          if (who === "a" && n === 1) {
            seen.put = await call(s, { action: "tools_put", path: ".local/bin/hello", text: hello })
            seen.skill = await call(s, { action: "tools_put", path: ".claude/skills/deploy/SKILL.md", text: skill })
            seen.token = await call(s, { action: "tools_put", path: ".config/cloud-chief/mac.token", text: "stolen" })
            seen.settings = await call(s, { action: "tools_put", path: ".claude/settings.json", text: "{}" })
            seen.client = await call(s, { action: "tools_put", path: ".local/bin/chief-tools", text: "broken" })
            seen.dots = await call(s, { action: "tools_put", path: ".local/bin/../.config/x", text: "x" })
            seen.big = await call(s, { action: "tools_put", path: ".chief/tools/big.txt", text: "x".repeat(70_000) })
            seen.many = []
            for (let i = 0; i < 5; i++) seen.many.push((await call(s, { action: "tools_put", path: `.chief/tools/part${i}.txt`, text: "y".repeat(60_000) })).status)
            for (let i = 0; i < 5; i++) await call(s, { action: "tools_rm", path: `.chief/tools/part${i}.txt` })
            seen.list = await call(s, { action: "tools_list" })
          } else if (who === "b") {
            seen.otherList = await call(s, { action: "tools_list" })
            seen.otherRm = await call(s, { action: "tools_rm", path: ".local/bin/hello" })
            seen.otherPut = await call(s, { action: "tools_put", path: ".local/bin/hello", text: "#!/bin/sh\necho other\n" })
          } else if (who === "a" && n === 2) {
            seen.rm = await call(s, { action: "tools_rm", path: ".claude/skills/deploy/SKILL.md" })
          }
        }
      )
      const a = await enabledChief("chief-cc-tools-a", "cc")
      seen.a = a.chief.id
      const b = await enabledChief("chief-cc-tools-b", "cc")
      expect((await send(a.token, a.chief.main_conversation, "t1", "add a hello tool")).ok).toBe(true)
      await replies(a.token, a.chief.main_conversation, a.chief.id, 1)
      expect(seen.put.status).toBe(200)
      expect(seen.skill.status).toBe(200)
      // Token paths, the hook settings, the client itself and any path outside the tool folders are refused.
      for (const k of ["token", "settings", "client", "dots"]) expect(seen[k].status, k).toBe(400)
      expect(seen.big.status).toBe(413)
      // 4 x 60 KB fit the 256 KB total; the fifth does not.
      expect(seen.many).toEqual([200, 200, 200, 200, 413])
      expect(seen.list.body.tools.map((t: any) => t.path).sort()).toEqual([".claude/skills/deploy/SKILL.md", ".local/bin/hello"])

      // The next turn's machine gets the tools; the token file stays the Worker's.
      expect((await send(a.token, a.chief.main_conversation, "t2", "run hello")).ok).toBe(true)
      await replies(a.token, a.chief.main_conversation, a.chief.id, 2)
      const second = (cloud.started.at(-1)!.input as any).files
      expect(second[".local/bin/hello"]).toBe(hello)
      expect(second[".claude/skills/deploy/SKILL.md"]).toBe(skill)
      expect(second[".config/cloud-chief/mac.token"]).toBe("mac-token-test-not-real")
      expect(seen.rm.status).toBe(200)

      // Another Chief neither sees nor changes them; its own put is its own.
      expect((await send(b.token, b.chief.main_conversation, "t3", "list tools")).ok).toBe(true)
      await replies(b.token, b.chief.main_conversation, b.chief.id, 1)
      expect(seen.otherList).toMatchObject({ status: 200, body: { tools: [] } })
      expect(seen.otherRm.status).toBe(404)
      expect(seen.otherPut.status).toBe(200)

      // A's third turn: its hello unchanged, the removed skill gone.
      expect((await send(a.token, a.chief.main_conversation, "t4", "again")).ok).toBe(true)
      await replies(a.token, a.chief.main_conversation, a.chief.id, 3)
      const third = (cloud.started.at(-1)!.input as any).files
      expect(third[".local/bin/hello"]).toBe(hello)
      expect(third[".claude/skills/deploy/SKILL.md"]).toBeUndefined()
    } finally {
      before === undefined ? delete testEnv.CHIEF_CC_TURN_FILES : (testEnv.CHIEF_CC_TURN_FILES = before)
    }
  })

  it("writes a pasted PNG into the turn machine with the same sha256, before the turn starts, at the path its message line names", async () => {
    const cloud = fakeCloud(() => "I see the screenshot.")
    const { token, chief } = await enabledChief("chief-cc-attachment", "cc")
    const conversation = chief.main_conversation
    // A PNG over one exec's stdin, so the write goes in chunks.
    const png = new Uint8Array(1_700_000)
    png.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    for (let i = 8; i < png.length; i++) png[i] = (i * 31 + 7) & 0xff
    const hash = createHash("sha256").update(png).digest("hex")
    const intent = await http("POST", "/v1/home/attachments/intent", token, { conversation, sha256: hash, byte_count: png.byteLength, mime_type: "image/png", name: "Screenshot 9.47.59.png", width: 2880, height: 1800 })
    expect(intent.json?.ok, intent.text).toBe(true)
    if (intent.json.value.state !== "exists") {
      const put = await worker.fetch(intent.json.value.upload_url, { method: "PUT", body: png, headers: { "content-length": String(png.byteLength) } })
      expect(put.status, await put.clone().text()).toBe(200)
    }
    const part = { type: "attachment", hash, name: "Screenshot 9.47.59.png", mime_type: "image/png", byte_count: png.byteLength, width: 2880, height: 1800 }
    const sent = await op(token, "message.send", { conversation, client_msg_id: "a1", parts: [{ type: "text", text: "what is wrong here?" }, part] }, "a1")
    expect(sent.ok, JSON.stringify(sent)).toBe(true)
    await replies(token, conversation, chief.id, 1)

    const path = `/home/chief/work/.attachments/${hash}.png`
    const s = cloud.started[0]!
    expect(s.input.prompt).toContain(`[attachment: Screenshot 9.47.59.png, image/png 2880x1800 1.6 MB, file ${path}]`)
    // The bytes: the chunks written to the part file, in order, then renamed to the named path.
    const writes = cloud.execs.filter((e) => e.vm === s.vm && /cat >>? \/home\/chief\/work\/\.attachments\//.test(e.command))
    expect(writes.length).toBeGreaterThan(1)
    for (const w of writes) expect(w.stdin.byteLength).toBeLessThanOrEqual(1_000_000)
    const got = new Uint8Array(writes.reduce((n, w) => n + w.stdin.byteLength, 0))
    let at = 0
    for (const w of writes) [got.set(w.stdin, at), (at += w.stdin.byteLength)]
    expect(createHash("sha256").update(got).digest("hex")).toBe(hash)
    expect(cloud.execs.some((e) => e.vm === s.vm && e.command.includes(`mv -f`) && e.command.endsWith(`${path} && echo ok`))).toBe(true)
    // Owned by the agent user, mode 600; written before the turn started.
    expect(cloud.execs.some((e) => e.command.includes("chown chief:chief") && e.command.includes("chmod 600"))).toBe(true)
    const order = cloud.steps.filter((x) => x.startsWith(s.vm))
    expect(order.findIndex((x) => x.endsWith("cat")) >= 0 || order.findIndex((x) => x.endsWith("install")) >= 0).toBe(true)
    expect(order.findIndex((x) => x.endsWith("/opt/chief-cc/start.sh"))).toBeGreaterThan(order.findLastIndex((x) => x.endsWith("chown")))
    // The bytes are in no reply or run.
    const runs = (await http("GET", `/v1/chiefs/${chief.id}/runs?conversation=${conversation}`, token)).json.value.runs as Array<any>
    expect(JSON.stringify(runs)).not.toContain("iVBORw0KGgo")
  })

  it("does not write an attachment of another conversation into the turn machine", async () => {
    const cloud = fakeCloud(() => "ok")
    const { token, chief } = await enabledChief("chief-cc-attachment-other", "cc")
    const foreign = "ab".repeat(32)
    expect((await send(token, chief.main_conversation, "o1", `look at /home/chief/work/.attachments/${foreign}.png`)).ok).toBe(true)
    await replies(token, chief.main_conversation, chief.id, 1)
    const s = cloud.started[0]!
    expect(cloud.execs.filter((e) => e.vm === s.vm && e.command.includes(".attachments/"))).toHaveLength(0)
    expect(s.input.prompt).toContain(`${foreign}.png (not found in this conversation)`)
  })

  it("lets the Chief keep sandbox VMs of its own across turns: at most two, only its own, through the turn token", async () => {
    const seen: Record<string, any> = {}
    const call = async (s: Started, vm: unknown) => {
      const r = await notes(s, { run: s.run, vm })
      return { status: r.status, body: await r.json().catch(() => null) }
    }
    const cloud = fakeCloud(
      () => "sandboxes",
      async (s, n) => {
        if (n === 1) {
          seen.a = await call(s, { action: "create" })
          seen.b = await call(s, { action: "create" })
          seen.c = await call(s, { action: "create" })
          seen.exec = await call(s, { action: "exec", id: seen.a.body?.vm?.id, command: "echo hello" })
          seen.foreign = await call(s, { action: "exec", id: s.vm, command: "echo nope" })
          seen.del = await call(s, { action: "delete", id: seen.b.body?.vm?.id })
          seen.bad = await call(s, { action: "format-disk" })
        } else {
          seen.list = await call(s, { action: "list" })
        }
      }
    )
    const { token, user, chief } = await enabledChief("chief-cc-sandbox", "cc")
    expect((await send(token, chief.main_conversation, "v1", "make two sandboxes")).ok).toBe(true)
    await replies(token, chief.main_conversation, chief.id, 1)
    expect(seen.a.status).toBe(200)
    expect(seen.b.status).toBe(200)
    expect(seen.c.status).toBe(429)
    const sandbox = cloud.made.find((m) => m.id === seen.a.body.vm.id)!
    expect(sandbox.body.metadata).toMatchObject({ cmux_chief_sandbox: chief.id })
    expect(sandbox.body.customer).toEqual({ customerId: user })
    expect(sandbox.body.ttlSeconds).toBeLessThanOrEqual(12 * 3600)
    expect(seen.exec).toMatchObject({ status: 200, body: { exit: 0, stdout: "hello\n" } })
    expect(cloud.execs.map(({ vm, command }) => ({ vm, command }))).toContainEqual({ vm: seen.a.body.vm.id, command: "echo hello" })
    // The turn machine itself (or any VM it did not make) is not the Chief's sandbox.
    expect(seen.foreign.status).toBe(404)
    expect(cloud.execs.some((e) => e.command === "echo nope")).toBe(false)
    expect(seen.del.status).toBe(200)
    expect(cloud.deleted).toContain(seen.b.body.vm.id)
    expect(seen.bad.status).toBe(400)
    // The next turn still has the sandbox it kept (the turn machines themselves are gone).
    expect((await send(token, chief.main_conversation, "v2", "list them")).ok).toBe(true)
    await replies(token, chief.main_conversation, chief.id, 2)
    expect(seen.list.status).toBe(200)
    expect(seen.list.body.vms.map((v: any) => v.id)).toEqual([seen.a.body.vm.id])
    expect(cloud.deleted).not.toContain(seen.a.body.vm.id)
  })

  it("lets the Chief grow its own sandboxes (grow only, capped, then the guest filesystem grows), and size them at create", async () => {
    const seen: Record<string, any> = {}
    const call = async (s: Started, vm: unknown) => {
      const r = await notes(s, { run: s.run, vm })
      return { status: r.status, body: await r.json().catch(() => null) }
    }
    const cloud = fakeCloud(
      () => "resized",
      async (s) => {
        seen.a = await call(s, { action: "create" })
        const id = seen.a.body?.vm?.id
        seen.grow = await call(s, { action: "resize", id, cpu: 8, memory_mb: 16384, disk_gb: 64 })
        seen.shrink = await call(s, { action: "resize", id, cpu: 2 })
        seen.huge = await call(s, { action: "resize", id, cpu: 4096 })
        seen.nothing = await call(s, { action: "resize", id })
        seen.junk = await call(s, { action: "resize", id, memory_mb: "lots" })
        seen.foreign = await call(s, { action: "resize", id: s.vm, cpu: 8 })
        seen.sized = await call(s, { action: "create", cpu: 6, memory_mb: 12288, disk_gb: 48 })
        seen.tiny = await call(s, { action: "create", disk_gb: 8 })
        seen.chiefImage = await call(s, { action: "create", image: "chief" })
      }
    )
    const { token, chief } = await enabledChief("chief-cc-sandbox-resize", "cc")
    expect((await send(token, chief.main_conversation, "r1", "grow the sandbox")).ok).toBe(true)
    await replies(token, chief.main_conversation, chief.id, 1)
    const id = seen.a.body.vm.id
    expect(seen.grow.status).toBe(200)
    expect(seen.grow.body).toMatchObject({ id, resources: { cpu: 8, memory_mb: 16384, disk_gb: 64 } })
    expect(cloud.resizes).toContainEqual({ vm: id, body: { cpu: 8, memory: 16384, storage: 65536 } })
    expect(cloud.sizes.get(id)).toEqual({ cpu: 8, memory: 16384, storage: 65536 })
    // The disk grew, so the guest's root filesystem is grown too and df shows it.
    expect(cloud.execs.some((e) => e.vm === id && e.command.includes("resize2fs"))).toBe(true)
    expect(seen.grow.body.df).toContain("63G")
    // The guest sees the new CPUs and memory before resize answers.
    expect(seen.grow.body.guest).toEqual({ nproc: 8, memory_mb: 16194, df: "/dev/vda 63G 1.2G 62G 2% /" })
    // Grow only, within the cap, a number on some axis, and only the Chief's own sandboxes; none reaches Freestyle.
    expect(seen.shrink.status).toBe(400)
    expect(seen.shrink.body.error).toMatch(/grow/)
    expect(seen.huge.status).toBe(400)
    expect(seen.nothing.status).toBe(400)
    expect(seen.junk.status).toBe(400)
    expect(seen.foreign.status).toBe(404)
    // One grow at create (the small default to 4 vCPU / 8 GiB), one asked for; the refused ones never reached Freestyle.
    expect(cloud.resizes.filter((r) => r.vm === id)).toEqual([{ vm: id, body: { cpu: 4, memory: 8192 } }, { vm: id, body: { cpu: 8, memory: 16384, storage: 65536 } }])
    expect(cloud.resizes.some((r) => r.vm !== id && !cloud.made.some((m) => m.id === r.vm && m.body.metadata?.cmux_chief_sandbox))).toBe(false)
    // create takes the same sizes.
    expect(seen.sized.status).toBe(200)
    expect(seen.sized.body.resources).toMatchObject({ cpu: 6, memory_mb: 12288, disk_gb: 48 })
    expect(cloud.sizes.get(seen.sized.body.vm.id)).toEqual({ cpu: 6, memory: 12288, storage: 49152 })
    // Small disks by default: the 16 GB Ubuntu base, grown to 4 vCPU / 8 GiB; below the base is refused; image chief is the Chief's own.
    expect(cloud.made.find((m) => m.id === id)!.body.snapshotId).toBe("freestyle/ubuntu-sm")
    expect(seen.a.body.resources).toEqual({ cpu: 4, memory_mb: 8192, disk_gb: 16 })
    // No idle pause by default (CLOUD_IDLE_PAUSE unset; auto-pause.ts, Leo 2026-10-30): Freestyle never pauses it for idleness.
    expect(cloud.made.find((m) => m.id === id)!.body.idleTimeoutSeconds).toBe(-1)
    expect(seen.a.body.idle_pause_seconds).toBe(-1)
    expect(seen.tiny.status).toBe(400)
    expect(seen.tiny.body.error).toMatch(/16 GB/)
    expect(seen.chiefImage.status, JSON.stringify(seen.chiefImage.body)).toBe(429)
  })

  it("runs sandbox execs on the Chief's own Freestyle identity: A's token cannot reach B's VM, revoked tokens are refused", async () => {
    const seen: Record<string, any> = {}
    const call = async (s: Started, vm: unknown) => {
      const r = await notes(s, { run: s.run, vm })
      return { status: r.status, body: await r.json().catch(() => null) }
    }
    const cloud = fakeCloud(
      () => "isolated",
      async (s, n) => {
        if (n === 1) {
          seen.a = await call(s, { action: "create" })
          seen.aExec = await call(s, { action: "exec", id: seen.a.body?.vm?.id, command: "whoami", user: "chief" })
          seen.badUser = await call(s, { action: "exec", id: seen.a.body?.vm?.id, command: "whoami", user: "nobody" })
        } else if (n === 2) {
          seen.b = await call(s, { action: "create" })
          seen.bExec = await call(s, { action: "exec", id: seen.b.body?.vm?.id, command: "echo b" })
        } else {
          seen.cross = await call(s, { action: "exec", id: seen.b.body?.vm?.id, command: "echo stolen" })
          for (const action of ["get", "update", "resize", "pause", "start", "stop", "delete"]) seen[`cross-${action}`] = await call(s, { action, id: seen.b.body?.vm?.id, cpu: 8, name: "x" })
          seen.aDel = await call(s, { action: "delete", id: seen.a.body?.vm?.id })
        }
      }
    )
    const A = await enabledChief("chief-cc-sandbox-a", "cc")
    const B = await enabledChief("chief-cc-sandbox-b", "cc")
    expect((await send(A.token, A.chief.main_conversation, "i1", "make one")).ok).toBe(true)
    await replies(A.token, A.chief.main_conversation, A.chief.id, 1)
    expect((await send(B.token, B.chief.main_conversation, "i2", "make one")).ok).toBe(true)
    await replies(B.token, B.chief.main_conversation, B.chief.id, 1)
    expect((await send(A.token, A.chief.main_conversation, "i3", "reach theirs")).ok).toBe(true)
    await replies(A.token, A.chief.main_conversation, A.chief.id, 2)
    const a = seen.a.body.vm.id as string
    const b = seen.b.body.vm.id as string
    expect(seen.aExec).toMatchObject({ status: 200, body: { exit: 0, stdout: "chief\n" } })
    expect(seen.bExec).toMatchObject({ status: 200, body: { exit: 0, stdout: "b\n" } })
    expect(seen.badUser.status).toBe(400)
    // One identity per Chief; each holds a grant only on its own VM, Linux users named (never null).
    const byVm = (vm: string) => [...cloud.identities.entries()].filter(([, i]) => i.grants.has(vm)).map(([id]) => id)
    expect(byVm(b)).toHaveLength(1)
    expect(cloud.identities.get(byVm(b)[0]!)!.grants.get(b)).toEqual(["root", "chief"])
    // Every sandbox exec ran on the owner's identity token, never the team key.
    expect(cloud.execAuth.filter((e) => e.vm === b).every((e) => e.by === `identity:${byVm(b)[0]}`)).toBe(true)
    expect(cloud.execAuth.some((e) => e.vm === a)).toBe(true)
    // A cannot touch B's VM through any verb, and nothing reached Freestyle for it.
    expect(seen.cross.status).toBe(404)
    for (const action of ["get", "update", "resize", "pause", "start", "stop", "delete"]) expect(seen[`cross-${action}`].status, action).toBe(404)
    expect(cloud.execs.some((e) => e.command === "echo stolen")).toBe(false)
    // B's only resize is its own create-time grow (the small default); A's cpu: 8 never reached Freestyle.
    expect(cloud.resizes.filter((r) => r.vm === b)).toEqual([{ vm: b, body: { cpu: 4, memory: 8192 } }])
    expect(cloud.deleted).not.toContain(b)
    // A's own token is refused on B's VM at Freestyle too (its grant names only A's VM).
    const aIdentity = cloud.execAuth.find((e) => e.vm === a)!.by.slice("identity:".length)
    const aToken = [...cloud.tokens.entries()].find(([, t]) => t.identity === aIdentity && !t.revoked)![0]
    const direct = await fetch(`https://freestyle.test/v5/vms/${b}/exec-await`, { method: "POST", headers: { "x-freestyle-identity-access-token": aToken, "content-type": "application/json" }, body: JSON.stringify({ command: "echo direct", linuxUser: "root" }) })
    expect(direct.status).toBe(403)
    // Deleting A's VM revoked its grant; archiving the Chief deletes its identity, and its token is refused.
    expect(seen.aDel.status).toBe(200)
    expect(cloud.identities.get(aIdentity)?.grants.has(a)).toBe(false)
    // Archive: the Chief's sandboxes pause and its identity goes (its default role moves to another Chief first).
    const other = (await op(A.token, "chief.create", { display_name: "Other Chief" }, "chief-cc-sandbox-a-other")).value as { id: string; rev: number }
    const listChiefs = async () => (await http("POST", "/v1/read", A.token, { op: "chief.list", params: {} })).json.value.chiefs as Array<any>
    const mine = (await listChiefs()).find((c) => c.id === A.chief.id)
    if (mine.is_default) expect((await op(A.token, "chief.update", { chief: other.id, expected_rev: (await listChiefs()).find((c) => c.id === other.id).rev, is_default: true })).ok).toBe(true)
    const rec = (await listChiefs()).find((c) => c.id === A.chief.id)
    const archived = await op(A.token, "chief.archive", { chief: A.chief.id, expected_rev: rec.rev })
    expect(archived.ok, JSON.stringify(archived)).toBe(true)
    for (let i = 0; i < 200 && cloud.identities.has(aIdentity); i++) await new Promise((r) => setTimeout(r, 20))
    expect(cloud.identities.has(aIdentity)).toBe(false)
    const revoked = await fetch(`https://freestyle.test/v5/vms/${a}/exec-await`, { method: "POST", headers: { "x-freestyle-identity-access-token": aToken, "content-type": "application/json" }, body: JSON.stringify({ command: "echo late", linuxUser: "root" }) })
    expect(revoked.status).toBe(401)
    // No token ever reached the turn machine.
    expect(JSON.stringify(seen)).not.toContain("idtok-secret")
  })

  it("gives the Chief the VM lifecycle, exec options, its cap and the cost per hour", async () => {
    const seen: Record<string, any> = {}
    const call = async (s: Started, vm: unknown) => {
      const r = await notes(s, { run: s.run, vm })
      return { status: r.status, body: await r.json().catch(() => null) }
    }
    const cloud = fakeCloud(
      () => "lifecycle",
      async (s) => {
        seen.made = await call(s, { action: "create", name: "builder", metadata: { purpose: "ci" }, idle_seconds: 600, ttl_seconds: 7200, snapshot: "freestyle/ubuntu" })
        const id = seen.made.body?.vm?.id
        seen.badSnap = await call(s, { action: "create", snapshot: "sh-someone-elses" })
        seen.reserved = await call(s, { action: "update", id, metadata: { cmux_chief_sandbox: "agent_other" } })
        seen.get = await call(s, { action: "get", id })
        seen.update = await call(s, { action: "update", id, name: "builder-2", idle_seconds: 900 })
        seen.exec = await call(s, { action: "exec", id, command: "printenv GREETING; cat", env: { GREETING: "hi" }, stdin: btoa("from stdin") })
        seen.badEnv = await call(s, { action: "exec", id, command: "true", env: { "1BAD": "x" } })
        seen.bigStdin = await call(s, { action: "exec", id, command: "cat", stdin: "A".repeat(190_000) })
        // The identity is deleted at Freestyle behind the Worker's back: the next exec makes a new one and works.
        for (const k of [...cloud.identities.keys()]) cloud.identities.delete(k)
        seen.afterLoss = await call(s, { action: "exec", id, command: "echo back" })
        seen.pause = await call(s, { action: "pause", id })
        seen.paused = await call(s, { action: "get", id })
        seen.start = await call(s, { action: "start", id })
        seen.stop = await call(s, { action: "stop", id })
        seen.cap = await call(s, { action: "cap" })
        seen.list = await call(s, { action: "list" })
        seen.tooBig = await call(s, { action: "resize", id, cpu: 33 })
        seen.second = await call(s, { action: "create" })
        seen.third = await call(s, { action: "create" })
      }
    )
    const before = testEnv.CHIEF_CC_SANDBOX_CAPS
    const beforeCap = testEnv.CHIEF_CC_SANDBOX_CAP
    const { token, chief } = await enabledChief("chief-cc-sandbox-life", "cc")
    // An empty per-Chief entry and an empty global value fall back to the default cap of 2 (never 0).
    testEnv.CHIEF_CC_SANDBOX_CAPS = `agent_unrelated=9,${chief.id}=`
    testEnv.CHIEF_CC_SANDBOX_CAP = ""
    try {
      expect((await send(token, chief.main_conversation, "l1", "lifecycle")).ok).toBe(true)
      await replies(token, chief.main_conversation, chief.id, 1)
    } finally {
      before === undefined ? delete testEnv.CHIEF_CC_SANDBOX_CAPS : (testEnv.CHIEF_CC_SANDBOX_CAPS = before)
      beforeCap === undefined ? delete testEnv.CHIEF_CC_SANDBOX_CAP : (testEnv.CHIEF_CC_SANDBOX_CAP = beforeCap)
    }
    const id = seen.made.body.vm.id
    const made = cloud.made.find((m) => m.id === id)!
    expect(made.body).toMatchObject({ snapshotId: "freestyle/ubuntu", displayName: "builder", idleTimeoutSeconds: 600, ttlSeconds: 7200, metadata: { purpose: "ci", cmux_chief_sandbox: chief.id } })
    // Cost per hour at list prices: 4 vCPU, 8 GiB, 32 GB running; disk only while paused.
    expect(seen.made.body.cost).toEqual({ running_usd_per_hour: 0.2672, paused_usd_per_hour: 0.0028 })
    expect(seen.badSnap.status).toBe(400)
    expect(seen.reserved.status).toBe(400)
    expect(seen.get.body.vm).toMatchObject({ id, state: "running", display_name: "builder", resources: { cpu: 4, memory_mb: 8192, disk_gb: 32 }, cost: { running_usd_per_hour: 0.2672 } })
    expect(seen.update.status).toBe(200)
    expect(cloud.patches).toContainEqual({ vm: id, body: { displayName: "builder-2", idleTimeoutSeconds: 900 } })
    expect(seen.exec).toMatchObject({ status: 200, body: { exit: 0, stdout: "hi\nfrom stdin" } })
    expect(seen.badEnv.status).toBe(400)
    expect(seen.bigStdin.status).toBe(400)
    expect(seen.bigStdin.body.error).toMatch(/fs put/)
    expect(seen.afterLoss).toMatchObject({ status: 200, body: { stdout: "back\n" } })
    // Every new sandbox gets the chief user that exec --user chief runs as.
    expect(cloud.execs.some((e) => e.vm === id && e.command === "id chief >/dev/null 2>&1 || useradd -m -s /bin/bash chief")).toBe(true)
    expect(seen.pause.body).toMatchObject({ state: "paused" })
    expect(seen.paused.body.vm.state).toBe("paused")
    expect(seen.start.body).toMatchObject({ state: "running" })
    expect(seen.stop.body).toMatchObject({ state: "stopped" })
    expect(cloud.execs.some((e) => e.vm === id && e.command.includes("poweroff"))).toBe(true)
    expect(seen.cap.body).toMatchObject({ cap: 2, live: 1, plan: { name: "pro", max: { cpu: 32, memory_mb: 65536, disk_gb: 256 } } })
    expect(seen.list.body.vms[0]).toMatchObject({ id, cost: { running_usd_per_hour: 0.2672 } })
    expect(seen.tooBig.status).toBe(400)
    expect(seen.tooBig.body.error).toMatch(/pro plan/)
    expect(seen.second.status).toBe(200)
    expect(seen.third.status).toBe(429)
  })

  it("keeps one sandbox list, cap and identity per Chief across its conversations, adopts older lists, and parallel creates stay in the cap", async () => {
    const seen: Record<string, any> = {}
    const call = async (s: Started, vm: unknown) => {
      const r = await notes(s, { run: s.run, vm })
      return { status: r.status, body: await r.json().catch(() => null) }
    }
    const cloud = fakeCloud(
      () => "shared",
      async (s, n) => {
        if (n === 1) {
          seen.list1 = await call(s, { action: "list" })
          seen.burst = await Promise.all([1, 2, 3].map(() => call(s, { action: "create" })))
        } else {
          seen.list2 = await call(s, { action: "list" })
          seen.exec2 = await call(s, { action: "exec", id: "vm-legacy", command: "echo still mine" })
        }
      }
    )
    const before = testEnv.CHIEF_CC_SANDBOX_CAP
    testEnv.CHIEF_CC_SANDBOX_CAP = "2"
    try {
      const { token, user, chief } = await enabledChief("chief-cc-sandbox-shared", "cc")
      // A sandbox the main conversation's brain kept before sandboxes moved to the Chief's own object.
      cloud.made.push({ id: "vm-legacy", body: { metadata: { cmux_chief_sandbox: chief.id } } })
      cloud.sizes.set("vm-legacy", { cpu: 4, memory: 8192, storage: 32768 })
      const ns = (testEnv as any).CHIEF_BRAIN_DO as DurableObjectNamespace
      const mainBrain = ns.get(ns.idFromName(`${chief.id}/${chief.main_conversation}`))
      await inDO(mainBrain, async (instance) => {
        instance.sql.exec(`CREATE TABLE IF NOT EXISTS cb_config (name TEXT PRIMARY KEY, value TEXT NOT NULL)`)
        instance.sql.exec(`INSERT INTO cb_config (name, value) VALUES ('cc_sandboxes', ?) ON CONFLICT (name) DO UPDATE SET value = excluded.value`, JSON.stringify([{ id: "vm-legacy", name: "old", created_at: 1 }]))
      })
      expect((await send(token, chief.main_conversation, "s1", "make sandboxes")).ok).toBe(true)
      await replies(token, chief.main_conversation, chief.id, 1)
      const created = await op(token, "conversation.create", { title: "Side work", participants: [{ id: user, kind: "human", display_name: "Owner" }, { id: chief.id, kind: "agent", agent_class: "mux", owner_user: user, display_name: "Route Chief" }] })
      expect(created.ok, JSON.stringify(created)).toBe(true)
      const side = created.value.conversation.id as string
      expect((await op(token, "message.send", { conversation: side, client_msg_id: "s2", parts: [{ type: "text", text: "@chief list them", runs: [{ start: 0, length: 6, mention: chief.id }] }] }, "s2")).ok).toBe(true)
      await replies(token, side, chief.id, 1)
      // The legacy sandbox was adopted and counts against the cap: of three parallel creates, exactly one fits.
      expect(seen.list1.body.vms.map((v: any) => v.id)).toEqual(["vm-legacy"])
      expect(seen.burst.map((r: any) => r.status).sort()).toEqual([200, 429, 429])
      // Another conversation of the same Chief sees the same two sandboxes and can use them.
      expect(seen.list2.body.vms.map((v: any) => v.id).sort()).toEqual(["vm-legacy", seen.burst.find((r: any) => r.status === 200).body.vm.id].sort())
      expect(seen.exec2).toMatchObject({ status: 200, body: { stdout: "still mine\n" } })
      // One identity for the Chief, and the conversation brain no longer keeps its own list.
      expect(new Set(cloud.execAuth.map((e) => e.by)).size).toBe(1)
      const left = await inDO(mainBrain, async (instance) => instance.sql.exec(`SELECT value FROM cb_config WHERE name = 'cc_sandboxes'`).toArray())
      expect(left).toEqual([])
    } finally {
      before === undefined ? delete testEnv.CHIEF_CC_SANDBOX_CAP : (testEnv.CHIEF_CC_SANDBOX_CAP = before)
    }
  })

  it("gives the Chief files (also while paused, chunked uploads), snapshots of its own and live forks", async () => {
    const seen: Record<string, any> = {}
    const call = async (s: Started, vm: unknown) => {
      const r = await notes(s, { run: s.run, vm })
      return { status: r.status, body: await r.json().catch(() => null) }
    }
    const big = Uint8Array.from({ length: 300_000 }, (_, i) => (i * 7) % 251)
    const b64 = (u: Uint8Array) => btoa(Array.from(u, (c) => String.fromCharCode(c)).join(""))
    const cloud = fakeCloud(
      () => "files",
      async (s) => {
        seen.made = await call(s, { action: "create" })
        const id = seen.made.body?.vm?.id
        const fs = (op: string, more: object) => call(s, { action: "fs", id, op, ...more })
        seen.write = await fs("write", { path: "/root/a.txt", data: btoa("hello file") })
        seen.relative = await fs("write", { path: "root/a.txt", data: btoa("x") })
        seen.pause = await call(s, { action: "pause", id })
        seen.read = await fs("read", { path: "/root/a.txt" })
        seen.readPart = await fs("read", { path: "/root/a.txt", offset: 6, length: 4 })
        seen.ls = await fs("ls", { path: "/root" })
        seen.stat = await fs("stat", { path: "/root/a.txt" })
        seen.exists = await fs("exists", { path: "/root/missing" })
        seen.begin = await fs("upload_begin", { path: "/root/big.bin", size: big.length })
        const up = seen.begin.body?.upload?.uploadId
        seen.chunks = []
        for (let off = 0; off < big.length; off += 128 * 1024) { const r = await fs("upload_chunk", { upload_id: up, offset: off, data: b64(big.subarray(off, off + 128 * 1024)) }); seen.chunks.push(r.status); (seen.chunkBodies ??= []).push(r.status === 200 ? 200 : r.body) }
        seen.tooBig = await fs("upload_chunk", { upload_id: up, offset: 0, data: b64(new Uint8Array(128 * 1024 + 1)) })
        seen.commit = await fs("upload_commit", { upload_id: up })
        seen.rm = await fs("rm", { path: "/root/a.txt" })
        seen.snap = await call(s, { action: "snapshot", id, name: "clean" })
        const snap = seen.snap.body?.snapshot?.id
        seen.snaps = await call(s, { action: "snapshots" })
        seen.rename = await call(s, { action: "snapshot_rename", snapshot: snap, name: "cleaner" })
        seen.foreignSnap = await call(s, { action: "snapshot_delete", snapshot: "sn-not-mine" })
        seen.fromSnap = await call(s, { action: "create", snapshot: snap })
        seen.fork = await call(s, { action: "fork", id, name: "try" })
        seen.forkOver = seen.fork
        seen.del = await call(s, { action: "snapshot_delete", snapshot: snap })
      }
    )
    const before = testEnv.CHIEF_CC_SANDBOX_CAP
    testEnv.CHIEF_CC_SANDBOX_CAP = "3"
    const { token, chief } = await enabledChief("chief-cc-sandbox-files", "cc")
    try {
      expect((await send(token, chief.main_conversation, "f1", "files")).ok).toBe(true)
      await replies(token, chief.main_conversation, chief.id, 1)
    } finally {
      before === undefined ? delete testEnv.CHIEF_CC_SANDBOX_CAP : (testEnv.CHIEF_CC_SANDBOX_CAP = before)
    }
    const id = seen.made.body.vm.id
    expect(seen.write).toMatchObject({ status: 200, body: { bytes: 10 } })
    expect(seen.relative.status).toBe(400)
    // Reads on a paused VM do not start it.
    expect(atob(seen.read.body.data)).toBe("hello file")
    expect(seen.read.body).toMatchObject({ size: 10, eof: true })
    expect(atob(seen.readPart.body.data)).toBe("file")
    expect(cloud.lifecycle).toEqual([`${id} pause`])
    expect(seen.ls.body.entries).toContainEqual({ name: "a.txt", kind: "file" })
    expect(seen.stat.body).toMatchObject({ size: 10, isFile: true })
    expect(seen.exists.body).toEqual({ exists: false })
    expect(seen.chunks, JSON.stringify(seen.chunkBodies)).toEqual([200, 200, 200])
    expect(seen.tooBig.status).toBe(400)
    expect(seen.commit.status).toBe(200)
    expect(cloud.files.get(id)!.get("/root/big.bin")).toEqual(big)
    expect(cloud.files.get(id)!.has("/root/a.txt")).toBe(false)
    // Snapshots: its own only, kept 7 days by default; a sandbox can start from one; fork = snapshot + create.
    expect(seen.snap.status).toBe(200)
    const snap = seen.snap.body.snapshot.id
    expect(cloud.snapshots.get(snap)).toMatchObject({ source: id, body: { displayName: "cleaner", ttlSeconds: 7 * 86_400 } })
    expect(seen.snaps.body.snapshots.map((x: any) => x.id)).toEqual([snap])
    expect(seen.rename.body.snapshot.name).toBe("cleaner")
    expect(seen.foreignSnap.status).toBe(404)
    expect(seen.fromSnap.status).toBe(200)
    expect(cloud.made.find((m) => m.id === seen.fromSnap.body.vm.id)!.body.snapshotId).toBe(snap)
    expect(seen.fork.status).toBe(200)
    expect(seen.fork.body).toMatchObject({ forked_from: id })
    expect(cloud.made.find((m) => m.id === seen.fork.body.vm.id)!.body.snapshotId).toBe(seen.fork.body.snapshot)
    expect(cloud.snapshots.get(seen.fork.body.snapshot)!.source).toBe(id)
    expect(seen.del.status).toBe(200)
    expect(cloud.snapshots.get(snap)!.deleted).toBe(true)
  })

  it("finishes a turn whose brain object was evicted while the machine worked: the machine's posts revive it", async () => {
    // Production, Oct 22: a long turn outlived its conversation brain object; the machine's notes and result
    // reached a fresh object with no running turn (401), and the turn later failed as "timeout" although the
    // reply was ready, so the person saw "I could not reach the model".
    const brainOf = (s: Started) => {
      const [, agent, conversation] = /\/v1\/chief-cc\/([^/]+)\/([^/]+)\/notes$/.exec(s.input.notes_url)!
      return testEnv.CHIEF_BRAIN_DO.get(testEnv.CHIEF_BRAIN_DO.idFromName(`${agent}/${conversation}`))
    }
    // The fake's own machine never posts (it runs on the brain object's timers, which the eviction ends); this
    // test plays the machine itself, from outside the object, as the real VM is.
    const cloud = fakeCloud(() => "unused", () => new Promise<void>(() => undefined))
    const { token, chief } = await enabledChief("chief-cc-evicted", "cc")
    expect((await send(token, chief.main_conversation, "e1", "a long task")).ok).toBe(true)
    for (let i = 0; i < 300 && cloud.started.length === 0; i++) await new Promise((r) => setTimeout(r, 20))
    const s = cloud.started[0]!
    await inDO(brainOf(s), async (_i, state) => {
      try {
        state.abort("test: evicted while the turn machine works")
      } catch {}
    }).catch(() => undefined)
    await machine(s, "Back after a restart.")
    const [reply] = await replies(token, chief.main_conversation, chief.id, 1)
    expect(reply.parts[0].text).toBe("Back after a restart.")
    expect(cloud.made).toHaveLength(1)
    expect(cloud.started).toHaveLength(1)
    const runs = (await http("GET", `/v1/chiefs/${chief.id}/runs?conversation=${chief.main_conversation}`, token)).json.value.runs as Array<any>
    expect(runs.map((r) => r.status)).toEqual(["done"])
  })

  it("refuses notes without the running turn's token, and after the turn ended", async () => {
    const cloud = fakeCloud(() => "noted")
    const { token, chief } = await enabledChief("chief-cc-notes", "cc")
    expect((await send(token, chief.main_conversation, "n1", "hello")).ok).toBe(true)
    await replies(token, chief.main_conversation, chief.id, 1)
    const s = cloud.started[0]!
    expect((await notes(s, { run: s.run, events: [] }, "not-the-token")).status).toBe(401)
    expect((await notes(s, { run: s.run, events: [] })).status).toBe(401)
    expect((await worker.fetch(s.input.notes_url, { method: "POST", body: "{}" })).status).toBe(401)
  })

  it.each([
    ["off the paid-model list", "chief-cc-other", false],
    ["on the paid-model list but not on the Claude Code route's list", "chief-cc-paid", "paid"]
  ] as const)("leaves an owner %s on the brain they had: no VM", async (_, sub, on) => {
    const cloud = fakeCloud(() => "never")
    const { token, chief } = await enabledChief(sub, on)
    expect((await send(token, chief.main_conversation, "o1", "hi there")).ok).toBe(true)
    const [reply] = await replies(token, chief.main_conversation, chief.id, 1)
    expect(reply.parts[0].text).not.toBe("never")
    expect(cloud.made).toHaveLength(0)
  })

  // Turns never fail silently (Lawrence, Oct 24: "super reliable"): a turn that ends early posts what it streamed, a
  // turn whose machine or model failed before anything ran is run again on a fresh machine, and a failed turn says
  // what happened in plain words, never "could not reach the model".
  const stream = (s: Started, events: Array<object>) => notes(s, { run: s.run, events })
  const progress = "Found it: the steering race is in brain-turn.ts. I pushed the fix and the deploy is running."
  const toolThenText = async (s: Started) => {
    await stream(s, [{ gen: 0, type: "tool", id: "toolu_a", name: "Bash", input: { command: "git push" } }, { gen: 0, type: "tool_done", id: "toolu_a", error: false }, { gen: 0, type: "done" }])
    await stream(s, [{ gen: 1, type: "text_start" }, { gen: 1, type: "text_delta", delta: progress }, { gen: 1, type: "text_done", text: progress }, { gen: 1, type: "done" }])
  }
  it.each([
    // The runner on the snapshot today: the time limit SIGKILLs Claude Code, the result is "failed" with no reply.
    ["the current runner", { status: "failed", reply: "", error: "claude exited on signal 9: ", total_ms: 20 * 60_000 }],
    // The runner that keeps the streamed text itself.
    ["a runner that keeps the text", { status: "partial", reason: "timeout", reply: progress, error: "the time limit stopped Claude Code", total_ms: 20 * 60_000 }]
  ])("posts what a long tool-heavy turn streamed when the time limit stops it (%s), not the failed notice", async (_, result) => {
    const cloud = fakeCloud(() => async (s) => {
      await toolThenText(s)
      await notes(s, { run: s.run, result: { ...result, model: s.input.model, last_gen: 1 } })
    })
    const { token, chief } = await enabledChief(`chief-cc-long-${result.status}`, "cc")
    expect((await send(token, chief.main_conversation, "l1", "fix the steering race and deploy")).ok).toBe(true)
    const [reply] = await replies(token, chief.main_conversation, chief.id, 1)
    expect(reply.parts[0].text).toBe(`${CC_PARTIAL.timeout}\n\n${progress}`)
    expect(reply.parts[0].text).not.toBe(TURN_FAILED_NOTICE)
    // Its tools ran: never run a second time.
    expect(cloud.started).toHaveLength(1)
    // The turn is given the time it has, in its prompt and as the machine's limit (Freestyle's run cap is above it).
    expect(cloud.started[0]!.input.max_ms).toBe(20 * 60_000)
    expect(cloud.started[0]!.input.system).toContain("You have 20 minutes for this turn")
    expect(cloud.made[0]!.body.maxRunSeconds).toBeGreaterThan(20 * 60 + 60)
    expect(cloud.made[0]!.body.ttlSeconds).toBeGreaterThan(cloud.made[0]!.body.maxRunSeconds)
  })

  it("runs a turn again on a fresh machine when its machine did not start, and says so only after three tries", async () => {
    const cloud = fakeCloud(() => "Started on the second machine.", undefined, (n) => n === 1)
    const { token, chief } = await enabledChief("chief-cc-boot-retry", "cc")
    expect((await send(token, chief.main_conversation, "b1", "hello")).ok).toBe(true)
    const [reply] = await replies(token, chief.main_conversation, chief.id, 1)
    expect(reply.parts[0].text).toBe("Started on the second machine.")
    expect(cloud.made).toHaveLength(2)
    expect(cloud.deleted).toContain("vm-test1")
    expect(cloud.started.map((s) => s.vm)).toEqual(["vm-test2"])

    const dead = fakeCloud(() => "never", undefined, () => true)
    const other = await enabledChief("chief-cc-boot-dead", "cc")
    expect((await send(other.token, other.chief.main_conversation, "b2", "hello")).ok).toBe(true)
    const [notice] = await replies(other.token, other.chief.main_conversation, other.chief.id, 1)
    expect(notice.parts[0].text).toBe(CC_NOTICES.machine)
    expect(dead.made).toHaveLength(3)
    expect(dead.started).toHaveLength(0)
    expect(dead.deleted.sort()).toEqual(dead.made.map((m) => m.id).sort())
  })

  it("runs a turn again once when the model failed before any tool ran, and never after a tool ran", async () => {
    const overloaded = { status: "failed", reply: "", error: "API Error: 529 overloaded" }
    const cloud = fakeCloud((_, n) => (n === 1 ? async (s) => void (await notes(s, { run: s.run, result: overloaded })) : "Second try worked."))
    const { token, chief } = await enabledChief("chief-cc-model-retry", "cc")
    expect((await send(token, chief.main_conversation, "m1", "hello")).ok).toBe(true)
    const [reply] = await replies(token, chief.main_conversation, chief.id, 1)
    expect(reply.parts[0].text).toBe("Second try worked.")
    expect(cloud.started.map((s) => s.vm)).toEqual(["vm-test1", "vm-test2"])

    const ran = fakeCloud(() => async (s) => {
      await stream(s, [{ gen: 0, type: "tool", id: "toolu_b", name: "Bash", input: { command: "rm -rf build" } }, { gen: 0, type: "tool_done", id: "toolu_b", error: false }])
      await notes(s, { run: s.run, result: overloaded })
    })
    const other = await enabledChief("chief-cc-model-after-tool", "cc")
    expect((await send(other.token, other.chief.main_conversation, "m2", "clean the build")).ok).toBe(true)
    const [notice] = await replies(other.token, other.chief.main_conversation, other.chief.id, 1)
    expect(notice.parts[0].text).toBe(CC_NOTICES.model)
    expect(notice.parts[0].text).not.toMatch(/try again|could not reach/i)
    expect(ran.started).toHaveLength(1)
  })
})
