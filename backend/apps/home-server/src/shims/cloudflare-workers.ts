/**
 * `cloudflare:workers` for the self-hosted server: the base classes the owner code extends. The
 * runtime (do-runtime/runtime.ts) builds objects as `new Class(ctx, env)`, as Workers does.
 */
export class DurableObject<Env = unknown> {
  protected readonly ctx: DurableObjectStateLike
  protected readonly env: Env
  constructor(ctx: DurableObjectStateLike, env: Env) {
    this.ctx = ctx
    this.env = env
  }
}

/** Entry points and RPC targets exist only as base classes here (no service bindings on a server). */
export class WorkerEntrypoint<Env = unknown> {
  protected readonly ctx: unknown
  protected readonly env: Env
  constructor(ctx: unknown, env: Env) {
    this.ctx = ctx
    this.env = env
  }
}
export class RpcTarget {}
export class WorkflowEntrypoint<Env = unknown> extends WorkerEntrypoint<Env> {}

/** The module-level env of Workers; the server fills it at start (unused by the chat owners). */
export const env: Record<string, unknown> = {}

type DurableObjectStateLike = object
