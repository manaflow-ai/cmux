import { readFileSync } from "node:fs"
import { dirname, resolve } from "node:path"

/**
 * A small JSON Schema validator for the keywords schemas/mobile-rpc uses: type, const, enum,
 * required, properties, additionalProperties, items, min/maxItems, min/maxLength, pattern,
 * minimum, maximum, oneOf, allOf and file-relative $ref. Any other keyword fails loudly, so a schema
 * can never silently accept what this validator does not check.
 */

type Schema = Record<string, unknown>
const SUPPORTED = new Set([
  "$schema", "$id", "title", "description", "$defs", "type", "const", "enum", "required", "properties",
  "additionalProperties", "items", "minItems", "maxItems", "minLength", "maxLength", "pattern", "minimum", "maximum", "oneOf", "allOf", "$ref"
])

export class SchemaSet {
  private readonly docs = new Map<string, Schema>()

  load(path: string): Schema {
    const abs = resolve(path)
    let doc = this.docs.get(abs)
    if (!doc) {
      doc = JSON.parse(readFileSync(abs, "utf8")) as Schema
      this.docs.set(abs, doc)
    }
    return doc
  }

  /** Validates `value` against the schema at `path` + JSON pointer; returns the error list (empty = valid). */
  validate(path: string, pointer: string, value: unknown): Array<string> {
    const errors: Array<string> = []
    this.check(resolve(path), this.at(this.load(path), pointer), value, "$", errors)
    return errors
  }

  has(path: string, pointer: string): boolean {
    try {
      this.at(this.load(path), pointer)
      return true
    } catch {
      return false
    }
  }

  private at(doc: Schema, pointer: string): Schema {
    let node: unknown = doc
    for (const part of pointer.replace(/^#\/?/, "").split("/").filter(Boolean)) {
      node = (node as Record<string, unknown>)[part.replace(/~1/g, "/").replace(/~0/g, "~")]
      if (node === undefined) throw new Error(`no schema at ${pointer}`)
    }
    return node as Schema
  }

  private check(file: string, schema: Schema, value: unknown, where: string, errors: Array<string>): void {
    for (const key of Object.keys(schema)) if (!SUPPORTED.has(key)) throw new Error(`unsupported keyword ${key} at ${where} in ${file}`)
    if (typeof schema.$ref === "string") {
      const [rel, pointer = ""] = schema.$ref.split("#")
      const target = rel ? resolve(dirname(file), rel) : file
      this.check(target, this.at(this.load(target), pointer), value, where, errors)
      return
    }
    if (Array.isArray(schema.oneOf)) {
      const passing = schema.oneOf.filter((s) => {
        const e: Array<string> = []
        this.check(file, s as Schema, value, where, e)
        return e.length === 0
      }).length
      if (passing !== 1) errors.push(`${where}: matches ${passing} of oneOf`)
      return
    }
    if (Array.isArray(schema.allOf)) {
      for (const part of schema.allOf) this.check(file, part as Schema, value, where, errors)
    }
    if (schema.type !== undefined) {
      const types = Array.isArray(schema.type) ? (schema.type as Array<string>) : [schema.type as string]
      if (!types.some((t) => typeMatches(t, value))) return void errors.push(`${where}: expected ${types.join("|")}`)
    }
    if ("const" in schema && JSON.stringify(schema.const) !== JSON.stringify(value)) errors.push(`${where}: expected ${JSON.stringify(schema.const)}`)
    if (Array.isArray(schema.enum) && !schema.enum.some((e) => JSON.stringify(e) === JSON.stringify(value))) errors.push(`${where}: ${JSON.stringify(value)} not in enum`)
    if (typeof value === "string") {
      if (typeof schema.minLength === "number" && [...value].length < schema.minLength) errors.push(`${where}: shorter than ${schema.minLength}`)
      if (typeof schema.maxLength === "number" && [...value].length > schema.maxLength) errors.push(`${where}: longer than ${schema.maxLength}`)
      if (typeof schema.pattern === "string" && !new RegExp(schema.pattern, "u").test(value)) errors.push(`${where}: ${JSON.stringify(value)} does not match ${schema.pattern}`)
    }
    if (typeof value === "number") {
      if (typeof schema.minimum === "number" && value < schema.minimum) errors.push(`${where}: below ${schema.minimum}`)
      if (typeof schema.maximum === "number" && value > schema.maximum) errors.push(`${where}: above ${schema.maximum}`)
    }
    if (Array.isArray(value)) {
      if (typeof schema.minItems === "number" && value.length < schema.minItems) errors.push(`${where}: fewer than ${schema.minItems} items`)
      if (typeof schema.maxItems === "number" && value.length > schema.maxItems) errors.push(`${where}: more than ${schema.maxItems} items`)
      if (schema.items) value.forEach((v, i) => this.check(file, schema.items as Schema, v, `${where}[${i}]`, errors))
    }
    if (value !== null && typeof value === "object" && !Array.isArray(value)) {
      const o = value as Record<string, unknown>
      for (const r of (schema.required as Array<string> | undefined) ?? []) if (!(r in o)) errors.push(`${where}: missing ${r}`)
      const props = (schema.properties as Record<string, Schema> | undefined) ?? {}
      for (const [k, v] of Object.entries(o)) {
        if (props[k]) this.check(file, props[k], v, `${where}.${k}`, errors)
        else if (schema.additionalProperties === false) errors.push(`${where}: unexpected ${k}`)
        else if (typeof schema.additionalProperties === "object") this.check(file, schema.additionalProperties as Schema, v, `${where}.${k}`, errors)
      }
    }
  }
}

const typeMatches = (t: string, v: unknown): boolean => {
  switch (t) {
    case "object":
      return v !== null && typeof v === "object" && !Array.isArray(v)
    case "array":
      return Array.isArray(v)
    case "integer":
      return typeof v === "number" && Number.isInteger(v)
    case "number":
      return typeof v === "number"
    case "null":
      return v === null
    default:
      return typeof v === t
  }
}
