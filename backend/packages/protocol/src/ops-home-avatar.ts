import { Schema } from "effect"
import { def, mutationErrors } from "./op-def.ts"
import { ConversationId, ParticipantId } from "./ops-home-schemas.ts"
import { isPattern } from "./json-checks.ts"

/**
 * Participant avatars (capability participant-avatars-v1 on the local owner; the same ops on the
 * Cloud owner): one picture per participant id, a person or a Chief. The bytes are kept once per
 * account by SHA-256 (R2 `avatars/<owner_user>/<sha256>`); the account's UserDO keeps the
 * references (the user's own and its Chiefs') and deletes a blob when no participant references
 * it. The media type comes from the bytes (PNG, JPEG, GIF or WebP), never from the caller.
 */
export const MAX_AVATAR_BYTES = 1024 * 1024
export const AvatarMediaType = Schema.Literals(["image/png", "image/jpeg", "image/gif", "image/webp"])
export const AvatarRef = Schema.Struct({
  sha256: Schema.String.check(isPattern(/^[0-9a-f]{64}$/)),
  media_type: AvatarMediaType,
  bytes: Schema.Int.check(Schema.isGreaterThanOrEqualTo(1), Schema.isLessThanOrEqualTo(MAX_AVATAR_BYTES))
}).annotate({ identifier: "AvatarRef", description: "A stored avatar: its SHA-256, its media type (from the bytes) and its size." })

const avatarErrors = [...mutationErrors, "forbidden", "avatar_invalid", "avatar_too_large", "unknown_participant"]

export const ParticipantAvatarSet = def({
  name: "participant.avatar.set",
  owner: "cloud:UserDO",
  class: "mutation",
  risk: "mutate-own",
  target: "participant",
  principals: ["session", "install"],
  params: Schema.Struct({
    participant_id: ParticipantId,
    bytes: Schema.optionalKey(Schema.String.annotate({ description: "The image, base64; at most 1048576 decoded bytes; PNG, JPEG, GIF or WebP by its signature." })),
    clear: Schema.optionalKey(Schema.Boolean.annotate({ description: "true removes the picture (no bytes)." }))
  }),
  result: Schema.Struct({ participant_id: ParticipantId, avatar: Schema.NullOr(AvatarRef) }),
  errors: avatarErrors,
  docs: "Set or clear a participant's avatar. A person sets only their own; the owner sets any of their Chiefs'; a Chief token never sets one; nobody sets another person's.",
  cli: { path: "avatar set", visible: true },
  mcp: { expose: "never", group: "home" }
})

export const ParticipantAvatarGet = def({
  name: "participant.avatar.get",
  owner: "cloud:UserDO",
  class: "read",
  risk: "read",
  target: "participant",
  principals: ["session", "install"],
  params: Schema.Struct({
    participant_id: ParticipantId,
    conversation: Schema.optionalKey(ConversationId.annotate({ description: "A conversation the caller and the participant are both in; needed unless the caller is the participant or the Chief's owner." }))
  }),
  result: Schema.Struct({
    participant_id: ParticipantId,
    avatar: Schema.NullOr(Schema.Struct({ ...AvatarRef.fields, data: Schema.String.annotate({ description: "The image, base64." }) }))
  }),
  errors: ["auth.forbidden", "validation.invalid", "selector.not_found"],
  docs: "A participant's avatar with its bytes, or null. The participant reads their own and an owner its Chief's; anyone else names a conversation both are in. Any other read is selector.not_found, the same answer as an unknown participant.",
  cli: { path: "avatar get", visible: true },
  mcp: { expose: "never", group: "home" }
})

export const homeAvatarOps = [ParticipantAvatarSet, ParticipantAvatarGet] as const
