/**
 * Text confirmation levels (home-messaging.md section 19), shared by the
 * per-user owner (`user/text-confirm-user.ts`, hosted by UserDO) and each
 * chief's projection (MuxDO):
 * - `strict` (default): destructive, money, send-external, access, irreversible;
 * - `destructive-only`: destructive and irreversible only;
 * - `off`: no confirmation.
 */
export type ConfirmLevel = "strict" | "destructive-only" | "off"
export const CONFIRM_LEVELS: ReadonlyArray<ConfirmLevel> = ["strict", "destructive-only", "off"]
/** Higher = riskier. */
export const RISK_RANK: Readonly<Record<ConfirmLevel, number>> = { strict: 0, "destructive-only": 1, off: 2 }
export const isRiskier = (to: ConfirmLevel, from: ConfirmLevel) => RISK_RANK[to] > RISK_RANK[from]
export const isLevel = (v: unknown): v is ConfirmLevel => typeof v === "string" && (CONFIRM_LEVELS as ReadonlyArray<string>).includes(v)
/** The safest of several levels (migration of per-chief values; several locks). */
export const safest = (levels: ReadonlyArray<ConfirmLevel>): ConfirmLevel | null =>
  levels.reduce<ConfirmLevel | null>((best, l) => (best === null || RISK_RANK[l] < RISK_RANK[best] ? l : best), null)

export interface LevelLock {
  readonly level: ConfirmLevel
  readonly by: "team_policy" | "mdm"
  /** Shown in Settings: the team name or the managing organization. */
  readonly name: string
  readonly at: number
}

/** One slot per source, so a team policy never lifts an MDM lock and the other way round. */
export interface LevelLocks {
  readonly team_policy?: LevelLock
  readonly mdm?: LevelLock
}

/** The lock in effect: the safest of the locks present (shown as "Locked by <name>"). */
export const effectiveLock = (locks: LevelLocks | null | undefined): LevelLock | null => {
  const present = [locks?.team_policy, locks?.mdm].filter((l): l is LevelLock => l !== undefined)
  return present.reduce<LevelLock | null>((best, l) => (best === null || RISK_RANK[l.level] < RISK_RANK[best.level] ? l : best), null)
}

/** Installs that are a person's app (never a daemon, CLI or VM install, where a chief may run). */
export const USER_APP_KINDS: ReadonlySet<string> = new Set(["mac", "ios", "web"])
