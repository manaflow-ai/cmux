import { AsyncLocalStorage } from "node:async_hooks"
import type { Env } from "./env.ts"

/**
 * The env of the request being served, for the op path (http.ts), which Effect's router runs without an env
 * argument. index.ts's fetch sets it from the request's build space (build-space.ts) around the router call, so
 * every op reaches its own build space's objects. Outside a request it throws: there is no space to fall back on.
 */
const current = new AsyncLocalStorage<Env>()

export const withRequestEnv = <T>(env: Env, serve: () => T): T => current.run(env, serve)

export const requestEnv = (): Env => {
  const env = current.getStore()
  if (!env) throw new Error("request env: read outside a request (index.ts sets it around the op path)")
  return env
}
