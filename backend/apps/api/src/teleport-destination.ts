/**
 * Where a teleport goes: one grammar for the Chief teleport (chief-brain/brain-teleport.ts) and
 * automation teleport (docs/automations-teleport-teams.md section 2), so `ssh:mini-1` means the
 * same machine to both and neither accepts an ssh option as a host.
 *
 * - `home`: the Mac the thing came from.
 * - `ssh:<host>[:<dir>]`: another machine; the host starts with a letter or digit.
 * - `local:<absolute dir>`: the Chief only (a directory on the same Mac).
 * - `cloud`: automations only (the team's SchedulerDO).
 *
 * At most 256 characters, no control characters.
 */
const SSH = /^ssh:[A-Za-z0-9][A-Za-z0-9._@-]*(?::.+)?$/
const LOCAL = /^local:\/.*$/
const CONTROL = /[\u0000-\u001f\u007f]/

const shaped = (to: unknown): to is string => typeof to === "string" && [...to].length <= 256 && !CONTROL.test(to)

/** The Chief teleport's destinations: the first problem, or null. */
export const destinationError = (to: unknown): string | null =>
  shaped(to) && (to === "home" || SSH.test(to) || LOCAL.test(to))
    ? null
    : 'to must be "home", "ssh:<host>[:<dir>]" or "local:<absolute dir>": at most 256 characters, no control characters'

/** An automation's destinations: the first problem, or null. */
export const automationDestinationError = (to: unknown): string | null =>
  shaped(to) && (to === "home" || to === "cloud" || SSH.test(to))
    ? null
    : 'to must be "cloud", "home" or "ssh:<host>[:<dir>]": at most 256 characters, no control characters'

/** A handoff id: `tp_` and 32 hex digits (the Chief teleport's request ids have the same shape). */
export const newHandoffId = (): string => `tp_${crypto.randomUUID().replaceAll("-", "")}`
