import type { ToolRegistration } from "@earendil-works/pi-durable"
import type { BrainConfig } from "../chief-brain/brain-store.ts"
import { ensureWasm, type Memory } from "../chief-brain/memory.ts"
import { ledgerApply, renderSystem, toolSpecs } from "../chief-brain/optchat-wasm/optchat_wasm.js"

/**
 * Cloud Chief D's side of the chief kernel (Native/OptChat/chief-kernel, cloud-chief-durable-DESIGN.md
 * section 13): the system text, the tool contract and the ledgers come from the kernel's wasm exports, so D
 * says and does what the Mac Chief does. D offers only the tools it can run without a machine.
 */

/** The kernel tools D runs: memory (pure, in the kernel) and the conversation ones (here). */
export const D_TOOLS: ReadonlyArray<string> = ["zoom", "date", "send", "reply", "stop"]
/** Kernel tools that answer in the kernel (`call_pure`). */
const PURE = new Set(["zoom", "date"])

/** What the conversation tools do, done by the Durable Object (posts are idempotent by the call's key). */
export interface KernelHost {
  memory(): Memory
  /** Posts `text` as the Chief, in the thread of view line `line` when given; answers what the model sees. */
  send(callId: string, text: string, line: number | undefined, attachments: ReadonlyArray<string>): Promise<string>
  /** The run ends after this round with nothing more posted. */
  stop(callId: string): void
}

type Spec = { name: string; description: string; json_schema: Record<string, unknown>; replay: "safe" | "once" }

/** The Chief's system text, as the Mac host renders it, with this Chief's record. */
export const kernelSystem = (cfg: BrainConfig): string => {
  ensureWasm()
  const record = { display_name: cfg.display_name ?? "Chief", role: cfg.role ?? "", personality: cfg.personality ?? "", instructions: cfg.instructions ?? "" }
  // The cloud section (chief-kernel mode "cloud"): no shell, no cmux CLI, the owner rule, and only the tools D offers.
  return renderSystem(JSON.stringify({ record }), "pi-durable", JSON.stringify({ mode: "cloud", offered: D_TOOLS }))
}

const text = (t: string) => ({ content: [{ type: "text" as const, text: t }] })

/** pi tool registrations for the kernel's specs that D runs, with the kernel's replay flags. */
export const kernelTools = (host: KernelHost): Array<ToolRegistration> => {
  ensureWasm()
  const specs = (JSON.parse(toolSpecs("pi-durable", JSON.stringify({ tools: D_TOOLS }))) as Array<Spec>).filter((s) => D_TOOLS.includes(s.name))
  return specs.map((s) => ({
    name: s.name,
    description: s.description,
    parameters: s.json_schema as never,
    // "once" tools are not rerun after a crash (pi gives the model an interrupted result instead).
    replay: s.replay === "safe" ? "safe" : "unsafe",
    execute: async (args: Record<string, unknown>, api: { callId: string }) => {
      if (PURE.has(s.name)) return text(host.memory().callPure(s.name, JSON.stringify(args), JSON.stringify({ utc_offset_minutes: 0 })))
      if (s.name === "stop") {
        host.stop(api.callId)
        return { ...text("Stopped: the turn ends now."), control: { terminate: true } }
      }
      const line = s.name === "reply" ? Number(args.id) : typeof args.reply_to === "number" ? args.reply_to : undefined
      const attachments = Array.isArray(args.attachments) ? (args.attachments as Array<string>) : []
      return text(await host.send(api.callId, String(args.text ?? ""), Number.isFinite(line) ? line : undefined, attachments))
    }
  })) as unknown as Array<ToolRegistration>
}

/** One step of the kernel's reply and outcome ledgers (chief-kernel ledger.rs): the new state and what to do. */
export type LedgerIntent = { kind: "schedule"; at_ms: number; key: string } | { kind: "notice"; text: string; key: string } | { kind: "post"; text: string; reply_to: string; key: string }
export const ledgerStep = (state: string, event: Record<string, unknown>, now: number): { state: string; intents: Array<LedgerIntent> } => {
  ensureWasm()
  const out = JSON.parse(ledgerApply(state, JSON.stringify(event), JSON.stringify({ now_ms: now }))) as { state: unknown; intents: Array<LedgerIntent> }
  return { state: JSON.stringify(out.state), intents: out.intents }
}
