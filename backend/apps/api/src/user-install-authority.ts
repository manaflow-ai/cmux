import { createHash } from "node:crypto"
import type { Principal } from "@cmux/ownership"
import type { UserState } from "./domains/user.ts"
import { grantFor, personalTeamIdFor, userPathAllowed } from "./domains/user.ts"
import { admit } from "./domains/common.ts"
import { installAuthorityVersion } from "./domains/user-authority.ts"
import type { Env } from "./env.ts"
import type { ReadResult } from "./owner-do.ts"

const refused = (): ReadResult => ({ ok: false, code: "auth.forbidden", message: "calling install authority changed or is unavailable" })

/** One calling install and one authenticated team; request params never select either owner. */
export const readInstallAuthority = async (env: Env, entity: string, principal: Principal, params: unknown,
  state: () => UserState, revision: () => string): Promise<ReadResult> => {
  if (params !== undefined && params !== null && (typeof params !== "object" || Array.isArray(params) || Object.keys(params).length !== 0)) {
    return { ok: false, code: "validation.invalid", message: "install.authority takes no selectors" }
  }
  const current = (): string | null => {
    const s = state(), i = principal.install ? s.installs[principal.install] : undefined
    if (principal.kind !== "install" || principal.agent !== undefined || principal.user !== entity || s.user?.id !== entity
      || !principal.team || !principal.install || !principal.grant || !i || !["mac", "ios", "cli"].includes(i.kind)
      || (principal.expires_at !== undefined && principal.expires_at <= Date.now())
      || !userPathAllowed(s, principal) || s.grants[principal.grant]?.grantee !== principal.install
      || admit("cloud:UserDO", "install.authority", principal, (p) => grantFor(s, p), Date.now())) return null
    return installAuthorityVersion(s, principal.install)
  }
  const before = current()
  if (!before) return refused()
  const team = principal.team!, user = principal.user!, install = principal.install!, grant = principal.grant!
  const owner = env.TEAM_DO.get(env.TEAM_DO.idFromName(team))
  // The personal owner checks the virtual pre-creation state and refuses missing/deleted membership.
  const teamVersion = team === personalTeamIdFor(user)
    ? await owner.personalScopeAuthority(team, user)
    : (await owner.membership(team, user))?.authority_version
  if (!teamVersion || !/^[0-9a-f]{64}$/.test(teamVersion) || current() !== before) return refused()
  const authority_version = createHash("sha256").update(JSON.stringify(["cmux-request-authority-v1", user, team, install, grant, before, teamVersion])).digest("hex")
  return { ok: true, value: { user, team, install, grant, authority_version }, revision: revision() }
}
