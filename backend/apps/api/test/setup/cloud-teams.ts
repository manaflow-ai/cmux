import { createHash } from "node:crypto"

/**
 * Cloud test teams on CLOUD_ALLOWED_TEAMS (vitest.config.ts): personal teams of the DO-level test
 * users 1..ALLOWED_USERS and of the Worker-level Stack subjects below. The derivations copy
 * domains/user.ts (userIdFor, personalTeamIdFor); cloud tests fail loudly if they drift.
 */
const hex20 = (s: string) => createHash("sha256").update(s).digest("hex").slice(0, 20)
export const ALLOWED_USERS = 200
/** Test Stack project (wrangler.jsonc top-level vars). */
export const TEST_STACK_PROJECT = "454ecd03-1db2-4050-845e-4ce5b0cd9895"
export const cloudTestUser = (i: number) => `user_${i.toString(16).padStart(4, "0")}${"0".repeat(16)}`
export const personalTeam = (user: string) => `team_${hex20(`personal:${user}`)}`
export const stackUser = (subject: string) => `user_${hex20(`stack:${TEST_STACK_PROJECT}:${subject}`)}`
export const ALLOWED_SUBJECTS = ["cloud-route-1", "cloud-route-2", "cloud-route-3", "cloud-route-4", "cloud-route-5", "cloud-bind-1", "cloud-bind-2", "cloud-bind-3", "cloud-bind-4", "cloud-bind-5", "cloud-bind-6"]
/** A non-personal (shared) team for team-machine access tests. */
export const SHARED_TEAM = "team_shared00000000000001"
export const cloudAllowedTeams = (): Array<string> => [
  ...Array.from({ length: ALLOWED_USERS }, (_, i) => personalTeam(cloudTestUser(i + 1))),
  ...ALLOWED_SUBJECTS.map((s) => personalTeam(stackUser(s))),
  SHARED_TEAM
]
