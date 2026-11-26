// The Worker as scripts/pair-matrix-worker.mjs runs it: index.ts's handler and its Durable Object classes only.
// workerd refuses a main module whose named exports include plain values (index.ts exports BUILD_SPACE_HEADER and
// helpers for the tests), so the local run starts from this module instead.
export { default, CloudAttentionPush, ConnectivityAlertDesk, HubRelay, LinkRelay, TeamHub } from "../src/index.ts"
