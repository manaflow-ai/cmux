import { Effect, Schema } from "effect"
import type { Env } from "../env.ts"
import { MODELS, modelById, type ModelEntry } from "./catalog.ts"

/**
 * The checks of one chat/completions request before any money moves, as one Effect program with
 * typed errors (backend TypeScript rule: Effect at the boundary). `validateChat` answers the model,
 * the bounded max_tokens and the prompt-token bound; route.ts maps each error to its HTTP answer.
 *
 * Model allowlist: INFERENCE_MODEL_ALLOWLIST narrows the catalog per deployment (staging and
 * production: DeepSeek V4.1 Flash 1017 only, user 2026-10-28). Unset = the whole catalog.
 *
 * Content: text parts always; `image_url` parts only for a vision model, at most its `maxImages`,
 * each billed at `tokensPerImage` before usage is known, so the reservation stays an upper bound.
 */

export class ChatRefused extends Schema.TaggedError<ChatRefused>()("ChatRefused", {
  status: Schema.Number,
  code: Schema.String,
  message: Schema.String
}) {}

export interface ValidChat {
  readonly model: ModelEntry
  /** Images in the request (each adds `vision.tokensPerImage` to the prompt bound). */
  readonly images: number
}

const refuse = (status: number, code: string, message: string) => Effect.fail(new ChatRefused({ status, code, message }))

/** The public model ids this deployment serves: the allowlist, or every catalog model. */
export const allowedModels = (env: Pick<Env, "INFERENCE_MODEL_ALLOWLIST">): ReadonlySet<string> => {
  const list = (env.INFERENCE_MODEL_ALLOWLIST ?? "").split(",").map((s) => s.trim()).filter(Boolean)
  return new Set(list.length > 0 ? list : MODELS.map((m) => m.id))
}

/** Counts image parts; refuses anything that is neither text nor (for a vision model) an image. */
const countImages = (messages: ReadonlyArray<unknown>, model: ModelEntry): Effect.Effect<number, ChatRefused> =>
  Effect.gen(function* () {
    let images = 0
    for (const m of messages) {
      if (!m || typeof m !== "object") return yield* refuse(400, "validation.invalid", "each message must be an object")
      const content = (m as { content?: unknown }).content
      if (content === undefined || content === null || typeof content === "string") continue
      if (!Array.isArray(content)) return yield* refuse(400, "validation.invalid", "message content must be a string or an array of parts")
      for (const part of content as Array<{ type?: unknown; image_url?: unknown }>) {
        if (part?.type === "text") continue
        if (part?.type !== "image_url") return yield* refuse(400, "validation.invalid", "only text and image_url content parts are accepted")
        if (!model.vision) return yield* refuse(400, "validation.invalid", `${model.id} does not take image input; send text only`)
        const url = typeof part.image_url === "string" ? part.image_url : (part.image_url as { url?: unknown } | undefined)?.url
        if (typeof url !== "string" || !(url.startsWith("https://") || url.startsWith("data:image/"))) return yield* refuse(400, "validation.invalid", "an image must be an https URL or a data:image/ URL")
        images++
      }
    }
    if (model.vision && images > model.vision.maxImages) return yield* refuse(400, "validation.invalid", `at most ${model.vision.maxImages} images per request`)
    return images
  })

/** The allowlist, model, messages, tools and content checks of one request. */
export const validateChat = (env: Pick<Env, "INFERENCE_MODEL_ALLOWLIST">, body: Record<string, unknown>): Effect.Effect<ValidChat, ChatRefused> =>
  Effect.gen(function* () {
    const allowed = allowedModels(env)
    const id = typeof body.model === "string" ? body.model : undefined
    const model = id ? modelById(id) : undefined
    if (id && model && !allowed.has(id)) return yield* refuse(403, "model.not_allowed", `this deployment serves only: ${[...allowed].join(", ")}`)
    if (!model) return yield* refuse(404, "model.not_found", `unknown model; the catalog allowlist is: ${[...allowed].join(", ")}`)
    if (!Array.isArray(body.messages) || body.messages.length === 0) return yield* refuse(400, "validation.invalid", "messages must be a non-empty array")
    if (body.tools !== undefined && !model.tools) return yield* refuse(400, "validation.invalid", "this model does not take tools")
    if (body.tools !== undefined && (!Array.isArray(body.tools) || (body.tools as Array<{ type?: unknown }>).some((t) => t?.type !== "function"))) return yield* refuse(400, "validation.invalid", "tools must be an array of function tools")
    if (body.n !== undefined && body.n !== 1) return yield* refuse(400, "validation.invalid", "n must be 1")
    const images = yield* countImages(body.messages as ReadonlyArray<unknown>, model)
    return { model, images }
  })
