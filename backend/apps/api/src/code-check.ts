import { codeBundlePath, type CodeRef } from "@cmux/protocol"
import { CodeStorage, teamRepoName, type CodeStorageEnv, type CodeStorageError, type HttpFetch } from "./code-storage.ts"

/**
 * Worker-side check before an op pins code (automation.create, update, deploy):
 * the commit exists in the caller team's repository and contains the bundle the
 * CLI builds (`<path>/dist/index.js`, decision A4). The reducer stays pure; this
 * check runs outside it. It is a fail-early check, not the security boundary:
 * the loader reads only the owner team's repository at run time.
 */

/** The code ref an op's params pin, when the op sets a code body. */
export const codeRefOf = (op: string, params: unknown): Pick<CodeRef, "path" | "commit"> | { readonly deploy: { automation: string; commit: string } } | undefined => {
  const p = (params ?? {}) as { body?: { type?: unknown; ref?: { path?: unknown; commit?: unknown } }; automation?: unknown; commit?: unknown }
  if (op === "automation.deploy") return typeof p.automation === "string" && typeof p.commit === "string" ? { deploy: { automation: p.automation, commit: p.commit } } : undefined
  if ((op === "automation.create" || op === "automation.update") && p.body?.type === "code" && typeof p.body.ref?.path === "string" && typeof p.body.ref.commit === "string") {
    return { path: p.body.ref.path, commit: p.body.ref.commit }
  }
  return undefined
}

/** Checks one ref in the team's repository. Malformed refs pass through: the owner's schema refuses them. */
export const checkCodeRef = async (env: CodeStorageEnv, team: string, ref: Pick<CodeRef, "path" | "commit">, http?: HttpFetch): Promise<CodeStorageError | undefined> => {
  if (!/^[0-9a-f]{40}$/.test(ref.commit) || !/^automations\/[a-z0-9][a-z0-9-]{0,62}$/.test(ref.path)) return undefined
  const store = new CodeStorage(env, http)
  const repo = teamRepoName(env.ENVIRONMENT, team)
  const commit = await store.commit(repo, ref.commit)
  if (!commit.ok) return commit
  const bundle = await store.hasFile(repo, ref.commit, codeBundlePath(ref))
  if (!bundle.ok) return bundle.code === "code.not_found" ? { ...bundle, message: `${codeBundlePath(ref)} is missing at ${ref.commit}: run the CLI deploy, which bundles before it pushes` } : bundle
  return undefined
}

/**
 * The check for one op, or undefined when the op pins no code. `readAutomation`
 * reads the caller's automation (deploy names only the automation and the commit).
 */
export const precheckCodeOp = async (
  env: CodeStorageEnv,
  team: string,
  op: string,
  params: unknown,
  readAutomation: (automation: string) => Promise<{ body?: { type?: string; ref?: { path?: string; commit?: string } } } | undefined>,
  http?: HttpFetch
): Promise<CodeStorageError | undefined> => {
  const target = codeRefOf(op, params)
  if (!target) return undefined
  const stored = typeof (params as { automation?: unknown } | null)?.automation === "string" ? await readAutomation((params as { automation: string }).automation) : undefined
  // An update that repeats the stored ref pins nothing new: no call, so it works while code.storage is down.
  // `export` is not compared: the check never validates it (the loader does, at run time).
  if (op === "automation.update" && "path" in target && stored?.body?.type === "code" && stored.body.ref?.path === target.path && stored.body.ref.commit === target.commit) return undefined
  if ("deploy" in target) {
    // Unknown or non-code automations: the owner gives the precise refusal.
    const path = stored?.body?.type === "code" ? stored.body.ref?.path : undefined
    if (typeof path !== "string") return undefined
    return checkCodeRef(env, team, { path, commit: target.deploy.commit }, http)
  }
  return checkCodeRef(env, team, target, http)
}
