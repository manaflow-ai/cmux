import { Schema } from "effect"
import { def } from "./op-def.ts"
import { GrantId, InstallId, TeamId, UserId } from "./schemas.ts"

export const InstallAuthority = def({
  name: "install.authority",
  owner: "cloud:UserDO",
  class: "read",
  risk: "read",
  target: "install",
  principals: ["install"],
  params: Schema.Struct({}),
  result: Schema.Struct({ user: UserId, team: TeamId, install: InstallId, grant: GrantId,
    authority_version: Schema.String.check(Schema.isPattern(/^[0-9a-f]{64}$/)) }),
  errors: ["auth.unauthenticated", "auth.forbidden", "validation.invalid", "owner.unreachable"],
  docs: "Read the authenticated client install's current account, team, grant and opaque cache version. Membership, role grants, policy and install admission changes invalidate the version. Takes no selectors, grants no permission and returns no credential. Server and chief installs cannot call this read.",
  cli: { path: "install authority", visible: false },
  mcp: { expose: "never", group: "account" }
})
