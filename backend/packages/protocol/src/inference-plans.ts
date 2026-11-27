/**
 * The plans that may use the hosted model router (cx-ds09i, Lawrence 2026-10-12: "paid teams on").
 * One owner for these ids; they are the paid plan ids of the web billing code
 * (web/services/billing/pro.ts PAID_PLAN_IDS), split by the sign-in service field that carries them:
 *
 * - A shared (Stack) team: the TEAM's `client_read_only_metadata.cmuxPlan`. Web billing writes "team"
 *   there while the team subscription is active and removes it when it lapses (syncTeamPlanMetadata).
 * - A personal team: its owner's USER `client_read_only_metadata.cmuxPlan`. Web billing (card
 *   checkout fulfillment, admin grants and verified App Store purchases) writes go, pro, max or
 *   founders there.
 *
 * Only `client_read_only_metadata` is read: a signed-in client can write `client_metadata`, so a
 * plan there proves nothing. `server_metadata` is not a billing field.
 */
export const INFERENCE_TEAM_PLAN_IDS: ReadonlySet<string> = new Set(["team"])
export const INFERENCE_PERSONAL_PLAN_IDS: ReadonlySet<string> = new Set(["go", "pro", "max", "founders"])

/** The catalog plan an `inference.plan_required` refusal names (what "See plans" offers a person). */
export const INFERENCE_ENTRY_PLAN = "pro"
