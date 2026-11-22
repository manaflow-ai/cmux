import { env } from "cloudflare:workers"

/**
 * Test support: the worker env with every TeamDO, UserDO and ConversationDO stub wrapped, so a
 * test can assert which reach RPCs (home-reach.ts) a request made. Pass `env` to
 * `conversationMutate`.
 */
const testEnv = env as unknown as { TEAM_DO: DurableObjectNamespace; USER_DO: DurableObjectNamespace; CONVERSATION_DO: DurableObjectNamespace }

/** Methods that resolve reach facts (home-reach.ts); none may run for a refused request. */
const REACH_METHODS = new Set(["homeCoMembers", "readInbox", "homeAllowRequestsFrom", "homeChiefDms", "homeDmLink", "mayInvite"])
/** The test env with every Durable Object stub wrapped so reach RPCs are recorded. */
export const recordingEnv = () => {
  const calls: Array<string> = []
  const wrap = (ns: DurableObjectNamespace, label: string) =>
    new Proxy(ns, {
      get(target, prop) {
        if (prop !== "get") {
          const value = Reflect.get(target, prop)
          return typeof value === "function" ? value.bind(target) : value
        }
        return (id: DurableObjectId) => {
          const stub = target.get(id) as unknown as Record<string, unknown>
          return new Proxy(stub, {
            get(s, method) {
              if (typeof method !== "string") return Reflect.get(s, method)
              // RPC stubs answer every property name; call through instead of binding.
              return (...args: Array<unknown>) => {
                if (REACH_METHODS.has(method)) calls.push(`${label}.${method}`)
                return (s[method] as (...a: Array<unknown>) => unknown)(...args)
              }
            }
          })
        }
      }
    })
  const recorded = { ...(env as object), TEAM_DO: wrap(testEnv.TEAM_DO, "team"), USER_DO: wrap(testEnv.USER_DO, "user"), CONVERSATION_DO: wrap(testEnv.CONVERSATION_DO, "conversation") }
  return { env: recorded as never, calls }
}
