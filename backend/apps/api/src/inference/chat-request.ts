import { Effect, Schema } from "effect"
import type { Env } from "../env.ts"
import { imageLimit, MODELS, modelById, routeImageLimit, type ModelEntry, type ProviderRoute } from "./catalog.ts"

/**
 * The checks of one chat/completions request before any money moves, as one Effect program with
 * typed errors (backend TypeScript rule: Effect at the boundary). `validateChat` answers the model,
 * the bounded max_tokens and the prompt-token bound; route.ts maps each error to its HTTP answer.
 *
 * Model allowlist: INFERENCE_MODEL_ALLOWLIST narrows the catalog per deployment (staging and
 * production: DeepSeek V4.1 Flash 1017 only, user 2026-10-28). Unset = the whole catalog.
 *
 * Content: text parts always; `image_url` parts only for a vision model, each billed at
 * `tokensPerImage` before usage is known, so the reservation stays an upper bound. A chat is never
 * locked out by its own history (`fitImages`): past the highest image limit of the routes that can
 * serve the request, the newest images go and each older one is replaced by a placeholder the model
 * reads (`omittedImages`, which route.ts returns in `x-cmux-images-omitted`). Only a new message (the
 * last one) that alone carries more images than every route takes is refused.
 */

export class ChatRefused extends Schema.TaggedError<ChatRefused>()("ChatRefused", {
  status: Schema.Number,
  code: Schema.String,
  message: Schema.String
}) {}

export interface ValidChat {
  readonly model: ModelEntry
  /** Where each image part of the request is, oldest first. */
  readonly images: ReadonlyArray<ImagePart>
}

/** The images of one request that fit its routes (`fitImages`). */
export interface FittedImages {
  /** Images sent to the provider (each adds `vision.tokensPerImage` to the prompt bound). */
  readonly images: number
  /** Older images replaced by `omittedImagePlaceholder` to fit the routes' per-request limit. */
  readonly omittedImages: number
  /** The messages to send: the request's own, or a copy with the omitted images replaced. */
  readonly messages: ReadonlyArray<unknown>
}

/** The text part the model reads in place of an older image past its per-request limit. */
export const omittedImagePlaceholder = (limit: number): string => `[earlier image not sent: limit ${limit} per request]`

const refuse = (status: number, code: string, message: string) => Effect.fail(new ChatRefused({ status, code, message }))

/** The public model ids this deployment serves: the allowlist, or every catalog model. */
export const allowedModels = (env: Pick<Env, "INFERENCE_MODEL_ALLOWLIST">): ReadonlySet<string> => {
  const list = (env.INFERENCE_MODEL_ALLOWLIST ?? "").split(",").map((s) => s.trim()).filter(Boolean)
  return new Set(list.length > 0 ? list : MODELS.map((m) => m.id))
}

/** One image part: its message's index and its index in that message's content. */
export interface ImagePart {
  readonly message: number
  readonly part: number
}

/** Where each image part is, oldest first; refuses anything that is neither text nor (for a vision model) an image. */
const findImages = (messages: ReadonlyArray<unknown>, model: ModelEntry): Effect.Effect<ReadonlyArray<ImagePart>, ChatRefused> =>
  Effect.gen(function* () {
    const found: Array<ImagePart> = []
    for (const [index, m] of messages.entries()) {
      if (!m || typeof m !== "object") return yield* refuse(400, "validation.invalid", "each message must be an object")
      const content = (m as { content?: unknown }).content
      if (content === undefined || content === null || typeof content === "string") continue
      if (!Array.isArray(content)) return yield* refuse(400, "validation.invalid", "message content must be a string or an array of parts")
      for (const [at, part] of (content as Array<{ type?: unknown; image_url?: unknown }>).entries()) {
        if (part?.type === "text") continue
        if (part?.type !== "image_url") return yield* refuse(400, "validation.invalid", "only text and image_url content parts are accepted")
        if (!model.vision) return yield* refuse(400, "validation.invalid", `${model.id} does not take image input; send text only`)
        const url = typeof part.image_url === "string" ? part.image_url : (part.image_url as { url?: unknown } | undefined)?.url
        if (typeof url !== "string" || !(url.startsWith("https://") || url.startsWith("data:image/"))) return yield* refuse(400, "validation.invalid", "an image must be an https URL or a data:image/ URL")
        found.push({ message: index, part: at })
      }
    }
    return found
  })

/**
 * The images of `messages` (found by `validateChat`) that fit `limit`, the highest image limit of the
 * routes that can serve the request: all of them, or the newest up to the limit with each older one
 * replaced by a placeholder. Refuses only a new (last) message that alone is past the limit.
 */
export const fitImages = (messages: ReadonlyArray<unknown>, found: ReadonlyArray<ImagePart>, model: ModelEntry, limit: number): Effect.Effect<FittedImages, ChatRefused> =>
  Effect.gen(function* () {
    if (found.length <= limit) return { images: found.length, omittedImages: 0, messages }
    const last = messages.length - 1
    if (found.filter((image) => image.message === last).length > limit) {
      return yield* refuse(400, "validation.invalid", `${model.id} takes at most ${limit} images in one message; send the rest in another message`)
    }
    const omitted = found.slice(0, found.length - limit)
    const placeholder = { type: "text", text: omittedImagePlaceholder(limit) }
    const replaced = messages.map((m, index) => {
      const parts = new Set(omitted.filter((image) => image.message === index).map((image) => image.part))
      if (parts.size === 0) return m
      const message = m as { content: ReadonlyArray<unknown> }
      return { ...message, content: message.content.map((part, at) => (parts.has(at) ? placeholder : part)) }
    })
    return { images: limit, omittedImages: omitted.length, messages: replaced }
  })

/** The images of one request fitted to its routes, and the routes that take them. */
export interface RoutedImages<R extends ProviderRoute> extends FittedImages {
  /** The highest image limit of the serving routes (what `fitImages` fitted to). */
  readonly limit: number
  /** The serving routes that take `images`, in their order; a route with a lower limit is skipped. */
  readonly routes: ReadonlyArray<R>
}

/**
 * Fits a request's images to the highest limit of `serving` (the routes that can serve it) and keeps
 * the routes that take that many: a route with a lower limit is skipped, never the cause of a refusal.
 */
export const fitToRoutes = <R extends ProviderRoute>(messages: ReadonlyArray<unknown>, found: ReadonlyArray<ImagePart>, model: ModelEntry, serving: ReadonlyArray<R>): Effect.Effect<RoutedImages<R>, ChatRefused> =>
  Effect.gen(function* () {
    const limit = imageLimit(model, serving)
    const fitted = yield* fitImages(messages, found, model, limit)
    return { ...fitted, limit, routes: serving.filter((route) => routeImageLimit(model, route) >= fitted.images) }
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
    const images = yield* findImages(body.messages as ReadonlyArray<unknown>, model)
    return { model, images }
  })
