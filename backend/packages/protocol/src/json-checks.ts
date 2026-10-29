import { Schema } from "effect"

// Effect 4.0 stable changed two JSON Schema exports the operation catalog, the generated clients
// and the op sidecars rely on. These keep what 4.0.0-rc.117 exported; runtime checks are unchanged.

/**
 * `Schema.isPattern` that keeps its `pattern` in JSON Schema. Effect 4.0 omits a RegExp constraint
 * (JSON Schema cannot carry RegExp flags) unless the filter supplies `toJsonSchema`. Flags are not
 * exported; no protocol pattern uses one.
 */
export const isPattern = (regExp: RegExp, annotations?: Parameters<typeof Schema.isPattern>[1]) =>
  Schema.isPattern(regExp, { toJsonSchema: () => ({ pattern: regExp.source }), ...annotations })

/**
 * `Schema.isMinLength` for a string whose values are ASCII (ids, base64url, addresses), exported as
 * `minLength: n`. Effect 4.0 exports `ceil(n / 2)`, because JSON Schema counts code points and a
 * JavaScript length counts UTF-16 units; for ASCII the two agree.
 */
export const isMinLength = (minLength: number) => {
  // Effect normalizes the bound before it validates; take only bounds it keeps as they are.
  if (!Number.isSafeInteger(minLength) || minLength < 0) throw new RangeError(`isMinLength: ${minLength} is not a length`)
  return Schema.isMinLength(minLength, { toJsonSchema: () => ({ minLength }) })
}
