import type { CloudSandbox, SandboxBootOptions, SandboxExecResult } from "./sandbox.ts"

/**
 * An in-memory CloudSandbox for tests: the second implementer of the interface, so it stays general.
 * `calls` records each call in order; `onExec` scripts guest answers.
 */
export class MemorySandbox implements CloudSandbox {
  readonly calls: Array<string> = []
  readonly machines = new Map<string, { readonly from: string }>()
  readonly snapshots = new Map<string, { readonly source: string; readonly name: string }>()
  /** Default guest: probes pass, a detached build starts and has already ended with exit 0. */
  onExec: (command: string, id: string) => SandboxExecResult | Promise<SandboxExecResult> = (command) =>
    ({ exitCode: 0, stdout: execKind(command) === "start" ? "started\n" : execKind(command) === "poll" ? "exit 0\n" : "", stderr: "" })
  private n = 0

  constructor(readonly provider = "memory") {}

  async boot(o: SandboxBootOptions) {
    if (o.snapshot !== undefined && !this.snapshots.has(o.snapshot)) throw new Error(`no snapshot ${o.snapshot}`)
    const id = `vm-${++this.n}`
    this.machines.set(id, { from: o.snapshot ?? "base" })
    this.calls.push(`boot:${o.snapshot ?? "base"}`)
    return { id }
  }

  async exec(id: string, command: string): Promise<SandboxExecResult> {
    if (!this.machines.has(id)) throw new Error(`no machine ${id}`)
    this.calls.push(`exec:${execKind(command)}`)
    return this.onExec(command, id)
  }

  async snapshot(id: string, name: string) {
    if (!this.machines.has(id)) throw new Error(`no machine ${id}`)
    const snap = `snap-${++this.n}`
    this.snapshots.set(snap, { source: id, name })
    this.calls.push("snapshot")
    return { id: snap }
  }

  async destroy(id: string) {
    this.machines.delete(id)
    this.calls.push("destroy")
  }
}

/** What a guest command is, for call logs: the readiness probe, the detached build's start or poll, or other. */
export const execKind = (command: string): "probe" | "start" | "poll" | "other" =>
  command === "true" ? "probe" : command.includes("nohup bash") ? "start" : command.includes("environment-build.exit") ? "poll" : "other"
