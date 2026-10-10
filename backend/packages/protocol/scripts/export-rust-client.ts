/**
 * Generates the Rust cmux.wire/1 client types (cmux-tui/crates/cmux-cloud-wire/src/generated/)
 * from the checked-in cloud catalog (backend/catalog/cloud-operations.json), next to
 * export-client.ts (TypeScript). The op set is the TypeScript client's: every catalog op
 * (internal ops are not in the catalog). Per op: a marker type implementing `Op`, a params
 * struct (without `expected_revision`, which travels in the envelope), the result type, and
 * an error enum of the declared codes. Named catalog types become structs, enums,
 * untagged unions or aliases. Error enums, multi-value string enums and unions keep a
 * value this build does not know in `Unknown` (forward compatibility). The output only uses the macros and helpers of the crate
 * (src/macros.rs, src/value.rs); no file exceeds the godfile budget.
 * Vector gate: cmux-tui/crates/cmux-cloud-wire/tests/cloud_vectors.rs.
 *
 *   bun scripts/export-rust-client.ts          write
 *   bun scripts/export-rust-client.ts --check  fail when the checked-in files differ
 */
import { readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { fileURLToPath } from "node:url"

type T = { kind: string; [k: string]: any }
type Field = { required: boolean; type: T; description?: string }

const catalogPath = fileURLToPath(new URL("../../../catalog/cloud-operations.json", import.meta.url))
const outDir = fileURLToPath(new URL("../../../../cmux-tui/crates/cmux-cloud-wire/src/generated", import.meta.url))
const catalog = JSON.parse(readFileSync(catalogPath, "utf8")) as {
  protocol: string
  types: Record<string, T>
  generics: Record<string, { parameters: Array<string>; type: T }>
  errors: Record<string, { retryable: boolean }>
  operations: Record<string, any>
}

const fail = (msg: string): never => {
  throw new Error(`export-rust-client: ${msg}`)
}

if (catalog.protocol !== "cmux.wire/1") fail(`protocol ${catalog.protocol}; the envelope is cmux.wire/1`)
// The envelope (src/envelope.rs) carries MutationResult's fields flat in OpResponse.
const mutationFields = Object.keys(catalog.generics.MutationResult?.type.fields ?? {}).sort().join(",")
if (mutationFields !== "replayed,revision,transaction,value") fail(`MutationResult fields ${mutationFields}; update src/envelope.rs`)

// ---------------------------------------------------------------- names

const RUST_KEYWORDS = new Set(
  "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self static struct super trait true type unsafe use where while abstract become box do final macro override priv try typeof unsized virtual yield gen".split(" ")
)
/** Idents of the hand-written crate items a generated name must not shadow. */
const RESERVED = new Set(["Op", "OpVisitor", "WireClass", "WireError", "WireIdempotency", "WirePrincipal", "OpRequest", "OpResponse", "ReadResponse", "OpError", "HttpError", "Origin", "BoolLit", "WireNumber", "Value", "BTreeMap", "Option", "String", "Vec", "Result", "Self"])

const words = (s: string): Array<string> =>
  s
    .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
    .replace(/([A-Z]+)([A-Z][a-z])/g, "$1 $2")
    .split(/[^A-Za-z0-9]+/)
    .filter(Boolean)
const pascal = (s: string): string => {
  const out = words(s)
    .map((w) => w[0]!.toUpperCase() + w.slice(1).toLowerCase())
    .join("")
  if (!out) fail(`no identifier in ${JSON.stringify(s)}`)
  return /^[0-9]/.test(out) ? `V${out}` : out
}
const snake = (s: string): string => {
  let out = words(s)
    .map((w) => w.toLowerCase())
    .join("_")
  if (!out) fail(`no field name in ${JSON.stringify(s)}`)
  if (/^[0-9]/.test(out)) out = `f_${out}`
  if (out === "self" || out === "super" || out === "crate") return `${out}_`
  return RUST_KEYWORDS.has(out) ? `r#${out}` : out
}
const rustString = (s: string): string =>
  `"${[...s]
    .map((c) => {
      const code = c.codePointAt(0)!
      if (c === "\\") return "\\\\"
      if (c === '"') return '\\"'
      if (code < 0x20 || code > 0x7e) return `\\u{${code.toString(16)}}`
      return c
    })
    .join("")}"`
const doc = (text: unknown, indent = ""): Array<string> =>
  typeof text === "string" && text.trim() ? [`${indent}/// ${text.replace(/\s+/g, " ").trim()}`] : []

// ---------------------------------------------------------------- items

/** One generated item: its lines and the file group it goes to. */
type Item = { name: string; lines: Array<string> }
const typeItems: Array<Item> = []
const literalItems = new Map<string, Item>()
const taken = new Map<string, string>()
const claim = (name: string, what: string) => {
  if (RESERVED.has(name)) fail(`${what}: ${name} is a hand-written crate item`)
  const prior = taken.get(name)
  if (prior) fail(`${what}: ${name} is already ${prior}`)
  taken.set(name, what)
}
for (const name of Object.keys(catalog.types)) {
  if (!/^[A-Z][A-Za-z0-9]*$/.test(name)) fail(`type name ${name} is not a Rust type name`)
  claim(name, `catalog type ${name}`)
}

const NON_FINITE = '["Infinity","-Infinity","NaN"]'
const isNonFiniteNumber = (t: T) =>
  t.kind === "union" &&
  t.variants.length === 2 &&
  t.variants[0].kind === "primitive" &&
  t.variants[0].name === "float64" &&
  t.variants[1].kind === "enum" &&
  JSON.stringify(t.variants[1].values) === NON_FINITE

const PRIMITIVES: Record<string, string> = { string: "String", decimal: "String", base64: "String", int64: "i64", int32: "i32", uint32: "u32", uint16: "u16", float64: "f64", boolean: "bool", json: "Value" }
const primitive = (name: string): string => PRIMITIVES[name] ?? fail(`primitive ${name} has no Rust type`)

/** The literal type of a single-value string enum (shared by value). */
const literal = (value: string): string => {
  const name = `Lit${pascal(value)}`
  const prior = literalItems.get(name)
  if (prior) {
    if (!prior.lines.some((l) => l.endsWith(` = ${rustString(value)}`))) fail(`literals ${name} collide`)
    return name
  }
  claim(name, `literal ${JSON.stringify(value)}`)
  literalItems.set(name, { name, lines: [`wire_literal! {`, `    ${name} = ${rustString(value)}`, `}`] })
  return name
}

/** The Rust type of `t`; inline objects, enums and unions become items named `name`. */
const rust = (t: T, name: string, into: Array<Item>, inUnion = false): string => {
  switch (t.kind) {
    case "primitive":
      return primitive(t.name)
    case "ref":
      if (!(t.name in catalog.types)) fail(`ref to unknown type ${t.name}`)
      return t.name
    case "array":
      return `Vec<${rust(t.items, `${name}Item`, into)}>`
    case "map":
      return `BTreeMap<String, ${rust(t.values, `${name}Value`, into)}>`
    case "nullable":
      return `Option<${rust(t.inner, name, into)}>`
    case "enum":
      return enumType(t, name, into, inUnion)
    case "union":
      if (isNonFiniteNumber(t)) return "WireNumber"
      claim(name, "union")
      into.push(unionItem(t, name, into))
      return name
    case "object":
      claim(name, "struct")
      into.push(structItem(t, name, into))
      return name
    default:
      return fail(`${name}: type kind ${t.kind} has no Rust type`)
  }
}

const enumType = (t: T, name: string, into: Array<Item>, inUnion: boolean): string => {
  const values = t.values as Array<unknown>
  if (values.length === 0) fail(`${name}: empty enum`)
  if (values.every((v) => typeof v === "boolean")) {
    if (values.length !== 1) return "bool"
    return `BoolLit<${values[0]}>`
  }
  if (!values.every((v) => typeof v === "string")) fail(`${name}: enum values must all be strings or booleans`)
  if (values.length === 1) return literal(values[0] as string)
  // An open enum would accept any string, so a union member must be a literal.
  if (inUnion) fail(`${name}: a multi-value enum as a union member is not supported`)
  claim(name, "enum")
  const variants = new Map<string, string>()
  for (const v of values as Array<string>) {
    let ident = pascal(v)
    if (ident === "Unknown" || ident === "Self") ident = `${ident}Value`
    const prior = variants.get(ident)
    if (prior !== undefined) fail(`${name}: values ${JSON.stringify(prior)} and ${JSON.stringify(v)} share the variant ${ident}`)
    variants.set(ident, v)
  }
  into.push({
    name,
    lines: [
      `wire_enum! {`,
      ...doc(t.description, "    "),
      `    ${name} {`,
      ...[...variants].map(([ident, v]) => `        ${ident} = ${rustString(v)},`),
      `    }`,
      `}`
    ]
  })
  return name
}

const fieldLines = (fields: Record<string, Field>, owner: string, into: Array<Item>): Array<string> => {
  const lines: Array<string> = []
  const seen = new Map<string, string>()
  for (const [key, f] of Object.entries(fields)) {
    const ident = snake(key)
    const bare = ident.replace(/^r#/, "")
    const prior = seen.get(bare)
    if (prior !== undefined) fail(`${owner}: fields ${prior} and ${key} share the name ${bare}`)
    seen.set(bare, key)
    const ty = f.type
    const nullable = ty.kind === "nullable"
    const isJson = ty.kind === "primitive" && ty.name === "json"
    const inner = rust(nullable ? ty.inner : ty, `${owner}${pascal(key)}`, into)
    const attrs: Array<string> = []
    if (bare !== key) attrs.push(`rename = ${rustString(key)}`)
    let rty: string
    if (f.required) {
      rty = nullable ? `Option<${inner}>` : inner
    } else if (nullable || isJson) {
      // Present (also as null) is Some; absent is None.
      rty = nullable ? `Option<Option<${inner}>>` : `Option<${inner}>`
      attrs.push(`default`, `skip_serializing_if = "Option::is_none"`, `with = "crate::value::present"`)
    } else {
      rty = `Option<${inner}>`
      attrs.push(`default`, `skip_serializing_if = "Option::is_none"`)
    }
    lines.push(...doc(f.description, "    "))
    if (attrs.length) lines.push(`    #[serde(${attrs.join(", ")})]`)
    lines.push(`    pub ${ident}: ${rty},`)
  }
  return lines
}

const DERIVE = "#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]"

const structItem = (t: T, name: string, into: Array<Item>): Item => {
  const fields = (t.fields ?? {}) as Record<string, Field>
  const body = fieldLines(fields, name, into)
  return { name, lines: [...doc(t.description), DERIVE, body.length ? `pub struct ${name} {` : `pub struct ${name} {}`, ...(body.length ? [...body, "}"] : [])] }
}

const unionItem = (t: T, name: string, into: Array<Item>): Item => {
  const variants: Array<string> = []
  // Unknown is the last member: what a newer backend adds decodes, verbatim.
  const idents = new Set<string>(["Unknown"])
  const add = (ident: string, ty: string) => {
    let id = ident
    for (let i = 2; idents.has(id); i++) id = `${ident}${i}`
    idents.add(id)
    variants.push(`    ${id}(${ty}),`)
  }
  for (const v of t.variants as Array<T>) {
    switch (v.kind) {
      case "object": {
        const tag = Object.values((v.fields ?? {}) as Record<string, Field>).find(
          (f) => f.required && f.type.kind === "enum" && f.type.values.length === 1 && typeof f.type.values[0] === "string"
        )
        const suffix = tag ? pascal(tag.type.values[0]) : `Variant${variants.length + 1}`
        add(suffix, rust(v, `${name}${suffix}`, into))
        break
      }
      case "ref":
        add(v.name, rust(v, name, into))
        break
      case "enum":
        add(pascal(String(v.values[0])), rust(v, name, into, true))
        break
      case "array":
        add("List", rust(v, `${name}List`, into))
        break
      case "primitive":
        add(pascal(v.name), rust(v, name, into))
        break
      default:
        fail(`${name}: union member kind ${v.kind} is not supported`)
    }
  }
  return {
    name,
    lines: [
      ...doc(t.description),
      DERIVE,
      "#[serde(untagged)]",
      `pub enum ${name} {`,
      ...variants,
      "    /// A member this build does not know (a newer backend), kept verbatim.",
      "    Unknown(Value),",
      "}"
    ]
  }
}

// Named catalog types, in name order.
const sortedTypes = Object.entries(catalog.types).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
for (const [name, t] of sortedTypes) {
  taken.delete(name) // claimed up front so inline names cannot take it
  const own: Array<Item> = []
  if (t.kind === "object") {
    claim(name, "struct")
    own.push(structItem(t, name, own))
  } else if (t.kind === "union" && !isNonFiniteNumber(t)) {
    claim(name, "union")
    own.push(unionItem(t, name, own))
  } else if (t.kind === "enum" && t.values.length > 1 && t.values.every((v: unknown) => typeof v === "string")) {
    enumType(t, name, own, false)
  } else {
    claim(name, "alias")
    own.push({ name, lines: [...doc(t.description), `pub type ${name} = ${rust(t, `${name}Inner`, own)};`] })
  }
  // The named item first, then the inline items it needs.
  const main = own.findIndex((i) => i.name === name)
  typeItems.push(own[main]!, ...own.filter((_, i) => i !== main))
}

// ---------------------------------------------------------------- ops

const opItems: Array<Item> = []
const ops = Object.entries(catalog.operations).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
const opIdents: Array<[string, string]> = []
const CLASSES: Record<string, string> = { read: "Read", mutation: "Mutation" }
const IDEMPOTENCY: Record<string, string> = { required: "Required", forbidden: "Forbidden", none: "None" }
const PRINCIPALS: Record<string, string> = { session: "Session", install: "Install" }
for (const [opName, op] of ops) {
  // The marker is <Name>Op: an op name may equal a type name (team_vm.status, TeamVmStatus).
  const base = pascal(opName)
  const ident = `${base}Op`
  claim(ident, `op ${opName}`)
  opIdents.push([opName, ident])
  const own: Array<Item> = []
  if (Object.keys(op.params.selectors ?? {}).length) fail(`${opName}: params selectors are not supported`)
  const params: T = {
    kind: "object",
    fields: Object.fromEntries(Object.entries(op.params.fields as Record<string, Field>).filter(([k]) => k !== "expected_revision"))
  }
  rust(params, `${base}Params`, own)
  let result: T = op.result
  if (op.class === "mutation") {
    if (result.kind !== "apply" || result.name !== "MutationResult" || result.arguments.length !== 1) fail(`${opName}: a mutation result must be MutationResult<T>`)
    result = result.arguments[0]
  }
  const resultType = rust(result, `${base}Result`, own)
  const errorName = `${base}Error`
  claim(errorName, `errors of ${opName}`)
  // Unknown is the macro's variant for a code the op does not declare.
  const errorIdents = new Map<string, string>([["Unknown", ""]])
  // A row may list a code twice (the backend joins shared and op lists); it is one variant.
  for (const code of new Set(op.errors as Array<string>)) {
    // Two codes may differ only in separators (idempotency.conflict, idempotency_conflict):
    // the later one in sort order gets a number.
    let e = pascal(code)
    for (let i = 2; errorIdents.has(e); i++) e = `${pascal(code)}${i}`
    errorIdents.set(e, code)
  }
  own.push({
    name: errorName,
    lines: [`wire_errors! {`, `    /// The error codes ${opName} declares.`, `    ${errorName} {`, ...[...errorIdents].filter(([, code]) => code !== "").map(([e, code]) => `        ${e} = ${rustString(code)},`), `    }`, `}`]
  })
  const principals = (op.principals as Array<string>).map((p) => PRINCIPALS[p] ?? fail(`${opName}: principal ${p}`))
  own.unshift({
    name: ident,
    lines: [
      `wire_op! {`,
      ...doc(op.docs, "    "),
      `    ${ident} {`,
      `        name: ${rustString(opName)},`,
      `        class: ${CLASSES[op.class] ?? fail(`${opName}: class ${op.class}`)},`,
      `        idempotency: ${IDEMPOTENCY[op.idempotency] ?? fail(`${opName}: idempotency ${op.idempotency}`)},`,
      `        owner: ${rustString(op.owner)},`,
      `        risk: ${rustString(op.risk)},`,
      `        principals: [${principals.join(", ")}],`,
      `        params: ${base}Params,`,
      `        result: ${resultType},`,
      `        error: ${errorName},`,
      `    }`,
      `}`
    ]
  })
  opItems.push(...own)
}

// ---------------------------------------------------------------- files

const HEADER = [
  "// GENERATED by backend/packages/protocol/scripts/export-rust-client.ts from",
  "// backend/catalog/cloud-operations.json. Do not edit; run `bun run catalog:rust` in backend/.",
  "#![cfg_attr(rustfmt, rustfmt::skip)]"
]
const PRELUDE = ["#[allow(unused_imports)]", "use super::*;"]
/** Splits items into files of at most `budget` lines (the godfile budget is 1000). */
const chunk = (prefix: string, items: Array<Item>, budget = 900): Array<[string, string]> => {
  const files: Array<Array<string>> = []
  let current: Array<string> = []
  for (const item of items) {
    if (current.length && current.length + item.lines.length + 1 > budget) {
      files.push(current)
      current = []
    }
    current.push(...(current.length ? [""] : []), ...item.lines)
  }
  if (current.length) files.push(current)
  return files.map((lines, i): [string, string] => [`${prefix}_${String(i + 1).padStart(2, "0")}.rs`, [...HEADER, ...PRELUDE, "", ...lines, ""].join("\n")])
}

const typeFiles = chunk("types", typeItems)
const literalFiles = chunk("literals", [...literalItems.values()].sort((a, b) => (a.name < b.name ? -1 : 1)))
const opFiles = chunk("ops", opItems)

const constName = (opName: string) => words(opName).map((w) => w.toUpperCase()).join("_")
const index = [
  ...HEADER,
  ...PRELUDE,
  "",
  "/// The wire name of every catalog op.",
  "pub mod op_names {",
  ...opIdents.map(([opName]) => `    pub const ${constName(opName)}: &str = ${rustString(opName)};`),
  "",
  "    /// Every catalog op name, sorted.",
  "    pub const ALL: &[&str] = &[",
  ...opIdents.map(([opName]) => `        ${constName(opName)},`),
  "    ];",
  "}",
  "",
  "/// Runs `visitor` with the op named `name`; `None` when the catalog has no such op.",
  "pub fn visit_op<V: crate::OpVisitor>(name: &str, visitor: V) -> Option<V::Output> {",
  "    Some(match name {",
  ...opIdents.map(([opName, ident]) => `        ${rustString(opName)} => visitor.visit::<${ident}>(),`),
  "        _ => return None,",
  "    })",
  "}",
  ""
].join("\n")
const constNames = new Set(opIdents.map(([n]) => constName(n)))
if (constNames.size !== opIdents.length) fail("two op names share a constant name")

const modules = [...typeFiles, ...literalFiles, ...opFiles].map(([f]) => f.replace(/\.rs$/, ""))
const mod = [
  ...HEADER,
  "//! The catalog types, literals and ops (`types_*`, `literals_*`, `ops_*`) and the op index.",
  "",
  "#[allow(unused_imports)]",
  "use crate::{BoolLit, WireNumber};",
  "#[allow(unused_imports)]",
  "use serde_json::Value;",
  "#[allow(unused_imports)]",
  "use std::collections::BTreeMap;",
  "",
  ...modules.map((m) => `mod ${m};`),
  "mod index;",
  "",
  ...modules.map((m) => `pub use ${m}::*;`),
  "pub use index::{op_names, visit_op};",
  ""
].join("\n")

const outputs = new Map<string, string>([["mod.rs", mod], ["index.rs", index], ...typeFiles, ...literalFiles, ...opFiles])
for (const [file, text] of outputs) {
  const lines = text.split("\n").length - 1
  if (lines > 1000) fail(`${file} has ${lines} lines (godfile budget 1000)`)
}

const existing = readdirSync(outDir).filter((f) => f.endsWith(".rs"))
if (process.argv.includes("--check")) {
  const drift = [...existing.filter((f) => !outputs.has(f)).map((f) => `${f} (stale)`)]
  for (const [file, want] of outputs) {
    let current = ""
    try {
      current = readFileSync(join(outDir, file), "utf8")
    } catch {}
    if (current !== want) drift.push(file)
  }
  if (drift.length) {
    console.error(`rust client drift in ${outDir}: ${drift.join(", ")}; run bun run catalog:rust`)
    process.exit(1)
  }
  console.log(`rust client ok: ${ops.length} ops, ${outputs.size} files`)
} else {
  for (const f of existing) if (!outputs.has(f)) rmSync(join(outDir, f))
  for (const [file, text] of outputs) writeFileSync(join(outDir, file), text)
  const total = [...outputs.values()].reduce((n, t) => n + t.split("\n").length - 1, 0)
  console.log(`wrote ${outDir}: ${ops.length} ops, ${Object.keys(catalog.types).length} types, ${outputs.size} files, ${total} lines`)
}
