import catalog from "../../../../catalog/cloud-operations.json"

/** Pure helpers of the tenant-isolation kit (no Worker bindings): op params generated from the operation catalog, id and shape scanners. Shared by the hermetic suite and the staging runner. */
type Type = any
const types = (catalog as any).types as Record<string, Type>
export const catalogOps = (catalog as any).operations as Record<string, { class: "read" | "mutation"; principals: Array<string>; owner: string; params: { fields: Record<string, { required: boolean; type: Type }> } }>
const CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
const LOWER = "abcdefghijklmnopqrstuvwxyz0123456789"
const fromClass = (cls: string): string => {
  if (cls.includes("0-9A-HJKMNP-TV-Z")) return CROCKFORD
  if (cls.includes("0-9a-hjkmnp-tv-z")) return CROCKFORD.toLowerCase()
  if (cls.includes("a-z0-9")) return LOWER
  if (cls.includes("0-9a-f")) return "0123456789abcdef"
  return "abcdefghijklmnopqrstuvwxyz0123456789_"
}
const rnd = (alphabet: string, n: number) => Array.from({ length: n }, () => alphabet[Math.floor(Math.random() * alphabet.length)]).join("")
/** A string that matches the simple `^literal[class]{n}$` patterns the id types use; undefined for a pattern it cannot build. */
export const fromPattern = (pattern: string): string | undefined => {
  const m = /^\^([A-Za-z_]*)\((?:dm_)?\)\?|^\^([A-Za-z_]*)(?:\[([^\]]+)\]\{(\d+)(?:,(\d+))?\})\$$/.exec(pattern)
  const simple = /^\^([A-Za-z_]*)\[([^\]]+)\]\{(\d+)(?:,(\d+))?\}\$$/.exec(pattern)
  if (simple) return simple[1] + rnd(fromClass(simple[2]!), Number(simple[3]))
  const conv = /^\^conv_\(dm_\)\?\[0-9A-HJKMNP-TV-Z\]\{26\}\$$/.exec(pattern)
  if (conv) return `conv_${rnd(CROCKFORD, 26)}`
  void m
  return undefined
}
const stringFor = (t: Type): string => {
  if (t.pattern) {
    const s = fromPattern(t.pattern)
    if (s !== undefined) return s
    if (t.pattern.includes("@")) return "x@tenant.test"
  }
  const min = t.min_length ?? 1
  return "x".repeat(Math.max(min, 1))
}
/** Sample a value of a catalog type. `ids` maps a ref name (MachineId ...) to a real id. */
export const sample = (t: Type, ids: Record<string, string>, depth = 0): unknown => {
  if (depth > 6) return null
  switch (t.kind) {
    case "ref": {
      if (ids[t.name]) return ids[t.name]
      if (t.name === "ParticipantId") return `user_${rnd(LOWER, 20)}`
      const def = types[t.name]
      return def ? sample(def, ids, depth + 1) : "x"
    }
    case "primitive":
      switch (t.name) {
        case "string":
          return stringFor(t)
        case "boolean":
          return false
        case "int64":
        case "int32":
        case "int":
        case "number":
        case "float64":
          return Math.max(t.minimum ?? 0, 1)
        case "decimal":
          return "1"
        default:
          return stringFor(t)
      }
    case "enum":
      return t.values?.[0]?.value ?? t.values?.[0] ?? t.variants?.[0]
    case "array":
      return (t.min_length ?? t.min_items) ? [sample(t.items, ids, depth + 1)] : []
    case "nullable":
      return null
    case "union":
      return sample((t.variants ?? t.members ?? t.options)[0], ids, depth + 1)
    case "object": {
      const out: Record<string, unknown> = {}
      for (const [k, f] of Object.entries<any>(t.fields ?? {})) if (f.required) out[k] = sample(f.type, ids, depth + 1)
      return out
    }
    case "map":
      return {}
    default:
      return null
  }
}
export const sampleParams = (op: string, ids: Record<string, string>) => {
  const out: Record<string, unknown> = {}
  // Required fields, plus every optional field that names a resource (a ref to an Id type): the other tenant's id
  // can hide in an optional parameter (cloud.machine.create from_snapshot).
  for (const [k, f] of Object.entries(catalogOps[op]!.params.fields)) if (f.required || (f.type.kind === "ref" && /Id$/.test(f.type.name))) out[k] = sample(f.type, ids)
  return out
}
/** Every id-shaped string in a JSON value, keyed by the catalog id type whose pattern it matches. */
export const idsIn = (value: unknown): Record<string, string> => {
  const found: Record<string, string> = {}
  const patterns = Object.entries(types).filter(([name, t]) => name.endsWith("Id") && t.kind === "primitive" && t.pattern).map(([name, t]) => [name, new RegExp(t.pattern)] as const)
  const walk = (v: unknown) => {
    if (typeof v === "string") {
      for (const [name, re] of patterns) if (!found[name] && re.test(v)) found[name] = v
    } else if (Array.isArray(v)) v.forEach(walk)
    else if (v && typeof v === "object") Object.values(v).forEach(walk)
  }
  walk(value)
  return found
}
/** Drop keys that change on every read (times, sequences, revisions) so two reads of an unchanged tenant compare equal. */
export const stable = (v: unknown): unknown => {
  if (Array.isArray(v)) return v.map(stable)
  if (v && typeof v === "object") return Object.fromEntries(Object.entries(v).filter(([k]) => !/(_at|^at|_ms|seq|revision|version|rev|cursor|stream|transaction|nonce)$/i.test(k)).map(([k, x]) => [k, stable(x)]))
  return v
}

/** Replace every id-shaped string and every long random-looking run so two replies about different ids compare equal in shape. */
export const shape = (raw: string): string =>
  raw
    .replace(/\b(user|team|vm|snap|conv|dev|inst|host|grp|auto|conn|run|fi|agent|grant|inv|msg|ws|trg|enr|lease|addr)_[0-9A-Za-z]{8,64}\b/g, "$1_<ID>")
    .replace(/"(transaction|idempotency_key|nonce)":"[^"]*"/g, '"$1":"<X>"')
    .replace(/\b\d{12,14}\b/g, "<T>")
    .replace(/"(revision|sequence|seq|n)":"?\d+"?/g, '"$1":<N>')
