import { Schema } from "effect"
import {
  DeviceId,
  DisplayName,
  Grant,
  Host,
  HostId,
  Install,
  InstallId,
  InstallKind,
  Platform,
  PublicJwk,
  TeamId,
  TeamMember,
  UserProfile
} from "./schemas.ts"

/**
 * Cloud operations, authored in Effect Schema (spec D7). `catalog:export`
 * writes them into the cmux operation catalog; the API Worker routes and
 * validates with the same definitions.
 */
export interface CloudOpDef<P extends Schema.Top = Schema.Top, R extends Schema.Top = Schema.Top> {
  readonly name: string
  readonly owner: "cloud:UserDO" | "cloud:TeamDO"
  readonly class: "read" | "mutation"
  readonly risk: "read" | "mutate-own" | "mutate-shared" | "execute" | "send-external" | "money" | "destructive"
  readonly target: string
  /** Who may call: a Stack session (human), an install token, or both. */
  readonly principals: ReadonlyArray<"session" | "install">
  readonly params: P
  readonly result: R
  readonly errors: ReadonlyArray<string>
  readonly docs: string
  readonly cli: { readonly path: string; readonly visible: boolean }
  readonly mcp: { readonly expose: "default" | "opt_in" | "never"; readonly group: string }
}

const def = <P extends Schema.Top, R extends Schema.Top>(d: CloudOpDef<P, R>) => d

const mutationErrors = ["validation.invalid", "idempotency.conflict", "revision.conflict", "auth.forbidden", "auth.unauthenticated"]

export const UserEnsure = def({
  name: "user.ensure",
  owner: "cloud:UserDO",
  class: "mutation",
  risk: "mutate-own",
  target: "user",
  principals: ["session"],
  params: Schema.Struct({}),
  result: UserProfile,
  errors: mutationErrors,
  docs: "Create or refresh the caller's user record from the Stack session.",
  cli: { path: "account ensure", visible: false },
  mcp: { expose: "never", group: "account" }
})

export const InstallRegister = def({
  name: "install.register",
  owner: "cloud:UserDO",
  class: "mutation",
  risk: "mutate-own",
  target: "install",
  principals: ["session"],
  params: Schema.Struct({
    public_jwk: PublicJwk,
    kind: InstallKind,
    name: DisplayName,
    device_name: DisplayName,
    platform: Platform,
    device: Schema.optionalKey(DeviceId)
  }),
  result: Install,
  errors: mutationErrors,
  docs: "Register an install's public key under the signed-in user; returns the install with its default grant.",
  cli: { path: "install register", visible: true },
  mcp: { expose: "never", group: "account" }
})

export const InstallRename = def({
  name: "install.rename",
  owner: "cloud:UserDO",
  class: "mutation",
  risk: "mutate-own",
  target: "install",
  principals: ["session", "install"],
  params: Schema.Struct({ install: InstallId, name: DisplayName }),
  result: Install,
  errors: [...mutationErrors, "selector.not_found"],
  docs: "Rename an install. An install may rename only itself; the user's session may rename any of its installs.",
  cli: { path: "install rename", visible: true },
  mcp: { expose: "opt_in", group: "account" }
})

export const InstallRevoke = def({
  name: "install.revoke",
  owner: "cloud:UserDO",
  class: "mutation",
  risk: "destructive",
  target: "install",
  principals: ["session"],
  params: Schema.Struct({ install: InstallId }),
  result: Install,
  errors: [...mutationErrors, "selector.not_found"],
  docs: "Revoke an install: its tokens stop working within one token lifetime and new tokens are refused.",
  cli: { path: "install revoke", visible: true },
  mcp: { expose: "never", group: "account" }
})

export const InstallList = def({
  name: "install.list",
  owner: "cloud:UserDO",
  class: "read",
  risk: "read",
  target: "install",
  principals: ["session", "install"],
  params: Schema.Struct({}),
  result: Schema.Struct({ user: Schema.NullOr(UserProfile), installs: Schema.Array(Install), grants: Schema.Array(Grant), revision: Schema.String }),
  errors: ["auth.unauthenticated"],
  docs: "List the caller's installs and grants.",
  cli: { path: "install list", visible: true },
  mcp: { expose: "default", group: "account" }
})

export const TeamDirectory = def({
  name: "team.directory",
  owner: "cloud:TeamDO",
  class: "read",
  risk: "read",
  target: "team",
  principals: ["session", "install"],
  params: Schema.Struct({ team: Schema.optionalKey(TeamId) }),
  result: Schema.Struct({ team: TeamId, members: Schema.Array(TeamMember), hosts: Schema.Array(Host), revision: Schema.String }),
  errors: ["auth.unauthenticated", "auth.forbidden"],
  docs: "Read a team's directory: members and enrolled hosts (U2).",
  cli: { path: "team directory", visible: true },
  mcp: { expose: "default", group: "team" }
})

export const HostEnroll = def({
  name: "host.enroll",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "host",
  principals: ["install"],
  params: Schema.Struct({ name: DisplayName, platform: Platform }),
  result: Host,
  errors: mutationErrors,
  docs: "Enroll the calling install's machine as a host in the team directory.",
  cli: { path: "host enroll", visible: true },
  mcp: { expose: "never", group: "team" }
})

export const HostRemove = def({
  name: "host.remove",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "destructive",
  target: "host",
  principals: ["session", "install"],
  params: Schema.Struct({ host: HostId }),
  result: Schema.Struct({ host: HostId }),
  errors: [...mutationErrors, "selector.not_found"],
  docs: "Remove a host from the team directory (its owner or a team admin).",
  cli: { path: "host remove", visible: true },
  mcp: { expose: "never", group: "team" }
})

export const cloudOps = [UserEnsure, InstallRegister, InstallRename, InstallRevoke, InstallList, TeamDirectory, HostEnroll, HostRemove] as const

export type CloudOpName = (typeof cloudOps)[number]["name"]

export const cloudOpByName: ReadonlyMap<string, CloudOpDef> = new Map(cloudOps.map((o) => [o.name, o as CloudOpDef]))
