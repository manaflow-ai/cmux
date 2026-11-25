import type { Env } from "./env.ts"

/**
 * The one switch for every automatic pause of a Freestyle VM (Leo, 2026-10-30: "we're saying no auto
 * pausing of the freestyle vms for now"). Off unless the Worker var CLOUD_IDLE_PAUSE is "on". Off means:
 * CloudDO's idle pause (team policy cloud.idlePause and each machine's idle policy), the 24 h idle
 * backstop, the 24 h no_report backstop and its stale_running alert all do nothing, whatever a team or
 * machine stored; and every Freestyle create or update we send asks for idleTimeoutSeconds -1 (never),
 * so Freestyle's own idle timer never pauses a VM either. A person's pause (cloud.machine.pause, the
 * Pause Machine action, `cmux cloud pause`, chief-vm pause) is not automatic and is unchanged. An automatic
 * pause already in the ledger when the switch is off never reaches the provider either (AUTO_PAUSE_OFF).
 */
export const autoPauseOn = (env: Pick<Env, "CLOUD_IDLE_PAUSE">): boolean => env.CLOUD_IDLE_PAUSE === "on"

/** Freestyle's idleTimeoutSeconds for a create or update: `seconds` with the switch on, else -1 (never pause for idleness). */
export const freestyleIdleSeconds = (env: Pick<Env, "CLOUD_IDLE_PAUSE">, seconds: number): number => (autoPauseOn(env) ? seconds : -1)

/**
 * The driver result of an automatic pause (pause_reason idle or no_report) that CloudDO's ledger still held
 * when the switch was off: never sent to the provider; the machine stays running with no error (cloud-power.ts).
 */
export const AUTO_PAUSE_OFF = "cloud.machine.auto_pause_off"
