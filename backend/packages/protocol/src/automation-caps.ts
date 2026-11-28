/**
 * The cloud ops automation code may call through `env.cmux.op` and the `op`
 * step type (automations plan slice 4, P13). An automation acts as itself: the
 * API Worker builds an `agent` principal for the automation (never a person's
 * session), with the op classes below, scoped to the automation's team. Every
 * name here must be a cloud op whose principals include `install` and whose risk
 * is in AUTOMATION_OP_CLASSES. Generated types: clients/ts/cloud/src/automation-cmux.ts.
 */
export const automationCapabilityOps = ["automation.list", "automation.get", "automation.runs.list", "automation.run", "usage.summary"] as const
export type AutomationCapabilityOp = (typeof automationCapabilityOps)[number]

/** Op classes (risks) an automation principal holds. */
export const AUTOMATION_OP_CLASSES: ReadonlyArray<string> = ["read", "execute"]
