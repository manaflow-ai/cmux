import { Schema } from "effect"

/**
 * `Schema.isPattern` that keeps its `pattern` in JSON Schema. Effect 4.0 stable omits a RegExp
 * constraint from JSON Schema export (JSON Schema cannot carry RegExp flags) unless the filter
 * supplies `toJsonSchema`. The catalog, the generated clients and the op sidecars carry these
 * patterns, so every protocol pattern goes through here. Flags are not exported; none is used.
 */
export const isPattern = (regExp: RegExp, annotations?: Parameters<typeof Schema.isPattern>[1]) =>
  Schema.isPattern(regExp, { toJsonSchema: () => ({ pattern: regExp.source }), ...annotations })
