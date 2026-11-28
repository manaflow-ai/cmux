/**
 * Home messaging core (plans/cmux-next/home-messaging.md): pure reducers and
 * pure invite logic. A Cloudflare adapter (DO SQLite) and a self-hosted
 * adapter run them; the conformance corpus (conformance/*.json) keeps every
 * owner, including the Rust `cmux-conversation`, on one protocol.
 *
 * Owners: conversation -> ConversationDO, inbox -> UserDO stream `inbox:`,
 * mux -> MuxDO, address -> AddressDO. Each is also a package subpath.
 */
export * as conversation from "./conversation/index.ts"
export * as inbox from "./inbox/index.ts"
export * as mux from "./mux/index.ts"
export * as address from "./address/index.ts"
export * as invites from "./invites/index.ts"
export * as user from "./user/index.ts"
export { conversationDomain } from "./conversation/index.ts"
export { inboxDomain } from "./inbox/index.ts"
export { muxDomain } from "./mux/index.ts"
export { addressDomain } from "./address/index.ts"
