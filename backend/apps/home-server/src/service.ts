import { existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs"
import { homedir, platform } from "node:os"
import { join } from "node:path"

/** The per-user service that runs `cmux-chat-server serve`. */
const LABEL = "com.cmux.chat-server"
const UNIT = "cmux-chat-server.service"

const run = (argv: Array<string>) => Bun.spawnSync(argv, { stdout: "pipe", stderr: "pipe" })

const plistPath = () => join(homedir(), "Library", "LaunchAgents", `${LABEL}.plist`)
const unitPath = () => join(process.env.XDG_CONFIG_HOME || join(homedir(), ".config"), "systemd", "user", UNIT)
const xml = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")

/** Installs and starts the service (launchd agent on macOS, systemd user unit on Linux). */
export const installService = (binary: string, dataDir: string): string => {
  if (platform() === "darwin") {
    mkdirSync(join(homedir(), "Library", "LaunchAgents"), { recursive: true })
    const log = join(dataDir, "server.log")
    writeFileSync(
      plistPath(),
      `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key><array><string>${xml(binary)}</string><string>serve</string><string>--data</string><string>${xml(dataDir)}</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${xml(log)}</string>
  <key>StandardErrorPath</key><string>${xml(log)}</string>
</dict></plist>
`
    )
    const uid = String(process.getuid?.() ?? 501)
    run(["launchctl", "bootout", `gui/${uid}/${LABEL}`])
    const r = run(["launchctl", "bootstrap", `gui/${uid}`, plistPath()])
    if (r.exitCode !== 0) throw new Error(`launchctl bootstrap failed: ${r.stderr.toString().trim()}`)
    return plistPath()
  }
  mkdirSync(join(unitPath(), ".."), { recursive: true })
  writeFileSync(
    unitPath(),
    `[Unit]
Description=cmux self-hosted chat server (Tailscale only)
After=network-online.target tailscaled.service

[Service]
ExecStart=${binary} serve --data ${dataDir}
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
`
  )
  run(["systemctl", "--user", "daemon-reload"])
  const r = run(["systemctl", "--user", "enable", "--now", UNIT])
  if (r.exitCode !== 0) throw new Error(`systemctl --user enable failed: ${r.stderr.toString().trim()}`)
  return unitPath()
}

/** Stops and removes the service. */
export const removeService = (): void => {
  if (platform() === "darwin") {
    run(["launchctl", "bootout", `gui/${process.getuid?.() ?? 501}/${LABEL}`])
    if (existsSync(plistPath())) rmSync(plistPath())
    return
  }
  run(["systemctl", "--user", "disable", "--now", UNIT])
  if (existsSync(unitPath())) rmSync(unitPath())
}

/** Whether the service is installed and running, as the OS reports it. */
export const serviceState = (): "running" | "stopped" | "not_installed" => {
  if (platform() === "darwin") {
    if (!existsSync(plistPath())) return "not_installed"
    return run(["launchctl", "print", `gui/${process.getuid?.() ?? 501}/${LABEL}`]).stdout.toString().includes("state = running") ? "running" : "stopped"
  }
  if (!existsSync(unitPath())) return "not_installed"
  return run(["systemctl", "--user", "is-active", UNIT]).stdout.toString().trim() === "active" ? "running" : "stopped"
}
