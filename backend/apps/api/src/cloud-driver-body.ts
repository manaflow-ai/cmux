import type { CreateOptions, VmTag } from "./cloud-driver.ts"

/**
 * One Freestyle TLS rule (CreateTlsRuleRequest, workers/cmux-vm/upstream/openapi.json). Inline at
 * create, `source: {}` means the VM being created; a later replace names it by `vmId`. Header values
 * are write-only at Freestyle (read back as `***`); never log a rule.
 */
export interface EdgeTlsRule {
  readonly action: "allow"
  readonly domain: string
  readonly source: { readonly vmId?: string }
  readonly destination: { readonly host: string; readonly port: number }
  readonly transform: ReadonlyArray<{ readonly headers: Readonly<Record<string, string>> }>
}

/**
 * The create body (Freestyle SDK 0.2.10 CreateVmOptions, web/services/vms/drivers/freestyle.ts):
 * - Every Freestyle timer is -1 (coordinator, 2026-10-05): idleTimeoutSeconds, autoDeleteSeconds,
 *   ttlSeconds, maxRunSeconds, maxRunTotalSeconds. Freestyle never pauses, stops or deletes a machine
 *   by itself, so our record stays true; idle is ours (the 24 h backstop and cloud.idlePause, from the
 *   VM's own reports, on the money-op path). automaticRestart true.
 * - firewall: a VM gets nothing implicitly; this allows egress to every publicly routable address.
 *   `public: true` selects by address, so it does not cover private or VPC addresses. The machine
 *   joins no VPC at create (no `vpcs`), so no VPC rule is needed now; the VPC attach work (lane 12)
 *   adds a `{ vpcId }` rule with the attach.
 * - size: create takes no resources (the snapshot decides; resize is a separate, grow-only call),
 *   so the plan checks cpu, memory and disk but the size is not sent yet.
 * - tls: the coderouter edge rule (cloud-coderouter-edge.ts), only when the create carries one.
 *   Rules must be inline: Freestyle writes the guest's hosts entry and egress CA only at create.
 */
export const createBody = (name: string, snapshot: string, tag: VmTag, opts: CreateOptions) => ({
  slug: name,
  snapshotId: snapshot,
  idleTimeoutSeconds: -1,
  autoDeleteSeconds: -1,
  ttlSeconds: -1,
  maxRunSeconds: -1,
  maxRunTotalSeconds: -1,
  automaticRestart: true,
  metadata: { cmux_next_team: tag.team, cmux_next_machine: tag.machine },
  firewall: { rules: [{ action: "allow", source: {}, destination: { public: true } }] },
  ...(opts.edgeRules?.length ? { tls: { rules: opts.edgeRules } } : {})
})
