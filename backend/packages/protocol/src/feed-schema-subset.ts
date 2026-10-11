/**
 * The JSON Schema subset the feed accepts for `input` forms and custom kinds'
 * `answer_schema` (plans/cmux-next/feed.md 3.4): one flat object of primitive
 * fields, the same shape as MCP elicitation's requested schema. Pure; the
 * cloud owner and the local owner (Rust, same vectors) validate the same way.
 */

export type SubsetResult = { readonly ok: true } | { readonly ok: false; readonly message: string }

const ok: SubsetResult = { ok: true }
const fail = (message: string): SubsetResult => ({ ok: false, message })

const FIELD_TYPES = new Set(["string", "number", "integer", "boolean", "array"])
const FORMATS = new Set(["email", "uri", "date", "date-time"])
const FIELD_KEYS = new Set(["type", "title", "description", "enum", "enumNames", "minLength", "maxLength", "minimum", "maximum", "format", "default", "items", "minItems", "maxItems"])
const MAX_FIELDS = 32
const NAME = /^[A-Za-z_][A-Za-z0-9_-]{0,63}$/

const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v)
const isInt = (v: unknown): v is number => typeof v === "number" && Number.isInteger(v)

const checkField = (name: string, f: unknown): SubsetResult => {
  if (!isObject(f)) return fail(`field ${name} is not an object`)
  for (const k of Object.keys(f)) if (!FIELD_KEYS.has(k)) return fail(`field ${name}: keyword ${k} is not supported`)
  if (typeof f.type !== "string" || !FIELD_TYPES.has(f.type)) return fail(`field ${name}: type must be string, number, integer, boolean or array`)
  if (f.enum !== undefined && f.type !== "string") return fail(`field ${name}: enum is only for string fields`)
  if (typeof f.minLength === "number" && typeof f.maxLength === "number" && f.minLength > f.maxLength) return fail(`field ${name}: minLength is above maxLength`)
  if (typeof f.minimum === "number" && typeof f.maximum === "number" && f.minimum > f.maximum) return fail(`field ${name}: minimum is above maximum`)
  if (f.enum !== undefined) {
    if (!Array.isArray(f.enum) || f.enum.length === 0 || f.enum.length > 64) return fail(`field ${name}: enum must have 1 to 64 values`)
    if (!f.enum.every((v) => typeof v === "string" && v.length <= 200)) return fail(`field ${name}: enum values must be strings`)
  }
  if (f.type === "array") {
    // Arrays are multi-select only: items are an enum of strings.
    const items = f.items
    if (!isObject(items) || items.type !== "string" || !Array.isArray(items.enum) || items.enum.length === 0 || items.enum.length > 64) return fail(`field ${name}: array items must be a string enum of 1 to 64 values`)
    if (!items.enum.every((v) => typeof v === "string")) return fail(`field ${name}: array enum values must be strings`)
  }
  if (f.format !== undefined && (f.type !== "string" || typeof f.format !== "string" || !FORMATS.has(f.format))) return fail(`field ${name}: format must be email, uri, date or date-time on a string`)
  for (const k of ["minLength", "maxLength", "minItems", "maxItems"] as const) if (f[k] !== undefined && (!isInt(f[k]) || (f[k] as number) < 0)) return fail(`field ${name}: ${k} must be a non-negative integer`)
  for (const k of ["minimum", "maximum"] as const) if (f[k] !== undefined && typeof f[k] !== "number") return fail(`field ${name}: ${k} must be a number`)
  for (const k of ["title", "description"] as const) if (f[k] !== undefined && (typeof f[k] !== "string" || (f[k] as string).length > 500)) return fail(`field ${name}: ${k} must be a string of at most 500 characters`)
  return ok
}

/** Validates the schema itself. */
export const checkSubsetSchema = (schema: unknown): SubsetResult => {
  if (!isObject(schema)) return fail("schema must be an object")
  for (const k of Object.keys(schema)) if (!["type", "properties", "required", "title", "description"].includes(k)) return fail(`schema keyword ${k} is not supported`)
  if (schema.type !== "object") return fail("schema type must be object")
  if (!isObject(schema.properties)) return fail("schema needs properties")
  const names = Object.keys(schema.properties)
  if (names.length === 0 || names.length > MAX_FIELDS) return fail(`schema needs 1 to ${MAX_FIELDS} fields`)
  for (const n of names) {
    if (!NAME.test(n)) return fail(`field name ${n} is not allowed`)
    const r = checkField(n, schema.properties[n])
    if (!r.ok) return r
  }
  if (schema.required !== undefined) {
    if (!Array.isArray(schema.required) || !schema.required.every((r) => typeof r === "string" && names.includes(r))) return fail("required must list declared fields")
  }
  return ok
}

const DATE = /^\d{4}-\d{2}-\d{2}$/
const DATE_TIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})$/
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
const URI = /^[A-Za-z][A-Za-z0-9+.-]*:\S+$/

const checkValue = (name: string, f: Record<string, unknown>, v: unknown): SubsetResult => {
  switch (f.type) {
    case "string": {
      if (typeof v !== "string") return fail(`${name} must be a string`)
      if (isInt(f.minLength) && v.length < f.minLength) return fail(`${name} is too short`)
      if (isInt(f.maxLength) && v.length > f.maxLength) return fail(`${name} is too long`)
      if (v.length > 16_000) return fail(`${name} is too long`)
      if (Array.isArray(f.enum) && !f.enum.includes(v)) return fail(`${name} is not one of the allowed values`)
      const fmt = f.format
      if (fmt === "email" && !EMAIL.test(v)) return fail(`${name} is not an email address`)
      if (fmt === "uri" && !URI.test(v)) return fail(`${name} is not a URI`)
      if (fmt === "date" && !DATE.test(v)) return fail(`${name} is not a date`)
      if (fmt === "date-time" && !DATE_TIME.test(v)) return fail(`${name} is not a date-time`)
      return ok
    }
    case "number":
    case "integer": {
      if (typeof v !== "number" || !Number.isFinite(v)) return fail(`${name} must be a number`)
      if (f.type === "integer" && !Number.isInteger(v)) return fail(`${name} must be an integer`)
      if (typeof f.minimum === "number" && v < f.minimum) return fail(`${name} is below the minimum`)
      if (typeof f.maximum === "number" && v > f.maximum) return fail(`${name} is above the maximum`)
      return ok
    }
    case "boolean":
      return typeof v === "boolean" ? ok : fail(`${name} must be true or false`)
    case "array": {
      const allowed = ((f.items as Record<string, unknown>).enum as Array<string>) ?? []
      if (!Array.isArray(v) || !v.every((x) => typeof x === "string" && allowed.includes(x))) return fail(`${name} must list allowed values`)
      if (new Set(v).size !== v.length) return fail(`${name} lists a value twice`)
      if (isInt(f.minItems) && v.length < f.minItems) return fail(`${name} needs more values`)
      if (isInt(f.maxItems) && v.length > f.maxItems) return fail(`${name} has too many values`)
      return ok
    }
    default:
      return fail(`${name} has an unsupported type`)
  }
}

/** Validates a value against a schema that passed `checkSubsetSchema`. Unknown keys are refused. */
export const checkSubsetValue = (schema: unknown, value: unknown): SubsetResult => {
  const s = schema as { properties: Record<string, Record<string, unknown>>; required?: Array<string> }
  if (!isObject(value)) return fail("the answer must be an object")
  for (const k of Object.keys(value)) if (!Object.hasOwn(s.properties, k)) return fail(`unknown field ${k}`)
  for (const r of s.required ?? []) if (!Object.hasOwn(value, r)) return fail(`${r} is required`)
  for (const [k, v] of Object.entries(value)) {
    const r = checkValue(k, s.properties[k]!, v)
    if (!r.ok) return r
  }
  return ok
}
