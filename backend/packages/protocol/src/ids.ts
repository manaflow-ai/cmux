import { Schema } from "effect"
import { isPattern } from "./json-checks.ts"

/** Public prefixed ids (cli.md C7). 20 lowercase alphanumeric characters after the prefix. */
export const prefixedId = (prefix: string, identifier: string, description: string) =>
  Schema.String.check(isPattern(new RegExp(`^${prefix}_[a-z0-9]{20}$`))).annotate({ identifier, description })

export const GrantId = prefixedId("grant", "GrantId", "A server-side grant; tokens carry only its id.")
