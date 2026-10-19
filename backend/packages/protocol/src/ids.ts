import { Schema } from "effect"

/** Public prefixed ids (cli.md C7). 20 lowercase alphanumeric characters after the prefix. */
export const prefixedId = (prefix: string, identifier: string, description: string) =>
  Schema.String.check(Schema.isPattern(new RegExp(`^${prefix}_[a-z0-9]{20}$`))).annotate({ identifier, description })

export const GrantId = prefixedId("grant", "GrantId", "A server-side grant; tokens carry only its id.")
