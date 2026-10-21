import { hostname } from "node:os"
import { parseArgs } from "node:util"
import { Admission } from "./admission.ts"
import { DEFAULT_PORT, defaultDataDir, liveAccess, readConfig, writeConfig } from "./config.ts"
import { Router } from "./router.ts"
import { buildServerRuntime } from "./server-env.ts"
import { listen } from "./server.ts"
import { installService, removeService, serviceState } from "./service.ts"
import { TailscaleCli } from "./tailscale.ts"

const USAGE = `usage: cmux-chat-server serve [--data DIR] [--port N]
       cmux-chat-server enable [--owner LOGIN] [--port N] [--data DIR] [--no-service]
       cmux-chat-server disable
       cmux-chat-server status [--json] [--data DIR]
       cmux-chat-server allow LOGIN | deny LOGIN [--data DIR]

A self-hosted cmux chat server (DMs and group chats). It listens only on this host's
Tailscale addresses and loopback; Tailscale identity (WhoIs) is the only credential.`

const die = (message: string): never => {
  console.error(`cmux-chat-server: ${message}`)
  process.exit(1)
}

const urlOf = (dns: string | null, port: number) => (dns ? `http://${dns}:${port}` : null)

const main = async (argv: Array<string>) => {
  const [verb, ...rest] = argv
  const { values, positionals } = parseArgs({
    args: rest,
    allowPositionals: true,
    options: { data: { type: "string" }, port: { type: "string" }, owner: { type: "string" }, json: { type: "boolean" }, "no-service": { type: "boolean" } }
  })
  const dataDir = values.data ?? defaultDataDir()
  const tailnet = new TailscaleCli()

  switch (verb) {
    case "serve": {
      const self = await tailnet.self()
      const config = readConfig(dataDir) ?? (self.login ? { owner: self.login, allow: [], port: DEFAULT_PORT } : die("no owner: run `cmux-chat-server enable --owner LOGIN` (this node is tagged or Tailscale is not running)"))
      const port = values.port ? Number(values.port) : config.port
      const tailnetAddresses = self.addresses
      if (tailnetAddresses.length === 0) console.error("cmux-chat-server: Tailscale is not up; serving loopback only until restart")
      const server = buildServerRuntime(dataDir)
      const rearmed = await server.runtime.rearmAlarms()
      const admission = new Admission(tailnet, liveAccess(dataDir, config), () => tailnetAddresses)
      const router = new Router(server, admission, () => ({ server_name: self.dns_name?.split(".")[0] ?? hostname(), url: urlOf(self.dns_name, port) }))
      // Only tailnet addresses and loopback: there is no public listener and no flag for one.
      listen(["127.0.0.1", ...tailnetAddresses], port, router, server)
      console.log(JSON.stringify({ msg: "cmux-chat-server listening", url: urlOf(self.dns_name, port), addresses: ["127.0.0.1", ...tailnetAddresses], port, owner: config.owner, allow: config.allow, data: dataDir, alarms_rearmed: rearmed }))
      const stop = () => {
        server.runtime.stop()
        process.exit(0)
      }
      process.on("SIGTERM", stop)
      process.on("SIGINT", stop)
      return
    }
    case "enable": {
      const self = await tailnet.self()
      if (self.addresses.length === 0) die("Tailscale is not running on this host (`tailscale up` first)")
      const owner = values.owner ?? self.login ?? die("this node is tagged: pass --owner LOGIN")
      const prior = readConfig(dataDir)
      writeConfig(dataDir, { owner, allow: prior?.allow ?? [], port: values.port ? Number(values.port) : (prior?.port ?? DEFAULT_PORT) })
      const where = values["no-service"] ? null : installService(process.execPath, dataDir)
      console.log(JSON.stringify({ ok: true, owner, url: urlOf(self.dns_name, readConfig(dataDir)!.port), service: where }, null, 2))
      return
    }
    case "disable":
      removeService()
      console.log(JSON.stringify({ ok: true, service: "removed" }))
      return
    case "allow":
    case "deny": {
      const login = positionals[0]?.toLowerCase() ?? die(`${verb} needs a LOGIN`)
      const c = readConfig(dataDir) ?? die("not enabled: run `cmux-chat-server enable` first")
      const allow = verb === "allow" ? [...c.allow, login] : c.allow.filter((l) => l !== login)
      writeConfig(dataDir, { ...c, allow })
      if (verb === "allow") console.error(`cmux-chat-server: ${login} may now use this server (DMs and groups with everyone on it)`)
      console.log(JSON.stringify({ ok: true, allow: readConfig(dataDir)!.allow }))
      return
    }
    case "status": {
      const self = await tailnet.self()
      const c = readConfig(dataDir)
      const port = c?.port ?? DEFAULT_PORT
      const health = await fetch(`http://127.0.0.1:${port}/healthz`).then((r) => r.ok).catch(() => false)
      const s = { enabled: c !== null, owner: c?.owner ?? null, allow: c?.allow ?? [], port, url: urlOf(self.dns_name, port), tailnet_addresses: self.addresses, service: serviceState(), answering: health, data: dataDir }
      console.log(values.json ? JSON.stringify(s) : Object.entries(s).map(([k, v]) => `${k}: ${Array.isArray(v) ? v.join(", ") : v}`).join("\n"))
      return
    }
    default:
      console.log(USAGE)
      if (verb && verb !== "help" && verb !== "--help") process.exit(2)
  }
}

await main(process.argv.slice(2))
