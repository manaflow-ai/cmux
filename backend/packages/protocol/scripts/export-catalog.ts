/**
 * Exports the cloud operations (authored in Effect Schema) into the cmux
 * operation catalog format (spec/operation-catalog.md, decision D7). The type
 * language matches cmux-tui/spec/resource-operations-v2.json (`kind`:
 * primitive/object/ref/array/enum/union/nullable/map/apply); each op also
 * carries JSON Schema 2020-12 sidecars for OpenAPI and MCP.
 *
 *   bun scripts/export-catalog.ts          write backend/catalog/cloud-operations.json
 *   bun scripts/export-catalog.ts --check  fail when the checked-in file differs
 */
import { readFileSync, writeFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { Schema } from "effect"
import { cloudOps, type CloudOpDef } from "../src/ops.ts"

type Json = null | boolean | number | string | Array<Json> | { [k: string]: Json }
type JsonSchema = { [k: string]: Json }
type TypeRef = { [k: string]: Json }

const types: Record<string, TypeRef> = {}

const convert = (js: JsonSchema, defs: Record<string, JsonSchema>): TypeRef => {
  if (typeof js.$ref === "string") {
    const name = js.$ref.split("/").pop()!
    if (!types[name]) {
      types[name] = { kind: "primitive", name: "json" } // placeholder breaks cycles
      types[name] = withDescription(convert(defs[name] ?? {}, defs), defs[name] ?? {})
    }
    return { kind: "ref", name }
  }
  const any = (js.anyOf ?? js.oneOf) as Array<JsonSchema> | undefined
  if (any) {
    const nonNull = any.filter((s) => s.type !== "null")
    const inner = nonNull.length === 1 ? convert(nonNull[0]!, defs) : { kind: "union", variants: nonNull.map((s) => convert(s, defs)) }
    return nonNull.length < any.length ? { kind: "nullable", inner } : inner
  }
  if (Array.isArray(js.enum)) return { kind: "enum", values: js.enum }
  if (js.const !== undefined) return { kind: "enum", values: [js.const] }
  switch (js.type) {
    case "string":
      return {
        kind: "primitive",
        name: "string",
        ...(typeof js.minLength === "number" ? { min_length: js.minLength } : {}),
        ...(typeof js.maxLength === "number" ? { max_length: js.maxLength } : {}),
        ...(typeof js.pattern === "string" ? { pattern: js.pattern } : {})
      }
    case "integer":
      return { kind: "primitive", name: "int64" }
    case "number":
      return { kind: "primitive", name: "float64" }
    case "boolean":
      return { kind: "primitive", name: "boolean" }
    case "array":
      return { kind: "array", items: js.items ? convert(js.items as JsonSchema, defs) : { kind: "primitive", name: "json" } }
    case "object": {
      const props = (js.properties ?? {}) as Record<string, JsonSchema>
      if (Object.keys(props).length === 0 && js.additionalProperties && typeof js.additionalProperties === "object") {
        return { kind: "map", values: convert(js.additionalProperties as JsonSchema, defs) }
      }
      const required = new Set((js.required ?? []) as Array<string>)
      return {
        kind: "object",
        fields: Object.fromEntries(
          Object.entries(props).map(([k, v]): [string, Json] => [k, { required: required.has(k), type: convert(v, defs), ...descriptionOf(v) }])
        )
      }
    }
    default:
      return { kind: "primitive", name: "json" }
  }
}

const descriptionOf = (js: JsonSchema): TypeRef => (typeof js.description === "string" ? { description: js.description } : {})
const withDescription = (t: TypeRef, js: JsonSchema): TypeRef => ({ ...t, ...descriptionOf(js) })

const jsonSchemaOf = (schema: Schema.Top) => {
  const doc = Schema.toJsonSchemaDocument(schema as never) as unknown as { schema: JsonSchema; definitions?: Record<string, JsonSchema> }
  return { schema: doc.schema, defs: doc.definitions ?? {} }
}

const entry = (op: CloudOpDef) => {
  const params = jsonSchemaOf(op.params)
  const result = jsonSchemaOf(op.result)
  const paramsType = convert(params.schema, params.defs) as { fields?: Json }
  const resultType = convert(result.schema, result.defs)
  const fields = { ...((paramsType.fields as Record<string, Json>) ?? {}) }
  if (op.class === "mutation") {
    fields.expected_revision = {
      required: false,
      type: { kind: "primitive", name: "decimal" },
      description: "Optimistic concurrency cursor revision. Omit for no revision precondition."
    }
  }
  return {
    class: op.class,
    idempotency: op.class === "mutation" ? "required" : "forbidden",
    target: op.target,
    ancestors: op.owner === "cloud:TeamDO" ? ["team"] : ["user"],
    params: { selectors: {}, fields, extra: false },
    result: op.class === "mutation" ? { kind: "apply", name: "MutationResult", arguments: [resultType] } : resultType,
    errors: [...op.errors].sort(),
    owner: op.owner,
    risk: op.risk,
    principals: op.principals,
    focuses: false,
    queue_offline: false,
    remote_relay: "deny",
    transport: { http: op.class === "mutation" ? { method: "POST", path: "/v1/ops" } : { method: "POST", path: "/v1/read" } },
    cli: op.cli,
    mcp: op.mcp,
    docs: op.docs,
    since: "cloud-1",
    input_json_schema: { ...params.schema, $defs: params.defs },
    output_json_schema: { ...result.schema, $defs: result.defs }
  }
}

const operations = Object.fromEntries([...cloudOps].sort((a, b) => a.name.localeCompare(b.name)).map((op) => [op.name, entry(op as CloudOpDef)]))

const catalog = {
  $schema: "./cloud-operations.schema.json",
  schema_version: 1,
  protocol: "cmux.wire/1",
  resource_scopes: ["team", "user", "device", "install", "grant", "host", "automation", "run", "connection"],
  types: Object.fromEntries(Object.entries(types).sort(([a], [b]) => a.localeCompare(b))),
  generics: {
    MutationResult: {
      parameters: ["T"],
      type: {
        kind: "object",
        fields: {
          value: { required: true, type: { kind: "parameter", name: "T" } },
          revision: { required: true, type: { kind: "primitive", name: "decimal" } },
          transaction: { required: true, type: { kind: "primitive", name: "string" } },
          replayed: { required: true, type: { kind: "primitive", name: "boolean" } }
        }
      }
    }
  },
  errors: {
    "validation.invalid": { retryable: false },
    "idempotency.conflict": { retryable: false },
    "revision.conflict": { retryable: false },
    "selector.not_found": { retryable: false },
    "operation.failed": { retryable: false },
    "auth.unauthenticated": { retryable: false },
    "auth.forbidden": { retryable: false },
    "owner.unreachable": { retryable: true },
    "mutation.indeterminate": { retryable: false }
  },
  operations
}

const out = fileURLToPath(new URL("../../../catalog/cloud-operations.json", import.meta.url))
const text = `${JSON.stringify(catalog, null, 2)}\n`
if (process.argv.includes("--check")) {
  let current = ""
  try {
    current = readFileSync(out, "utf8")
  } catch {}
  if (current !== text) {
    console.error(`catalog drift: ${out} differs from the Effect Schema definitions; run bun run catalog:export`)
    process.exit(1)
  }
  console.log(`catalog ok: ${Object.keys(operations).length} cloud ops`)
} else {
  writeFileSync(out, text)
  console.log(`wrote ${out}: ${Object.keys(operations).length} cloud ops, ${Object.keys(types).length} types`)
}
