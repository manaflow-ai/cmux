import type { ChannelClass } from "./mobile-wire.ts"

/**
 * The cmux.mobile/1 message catalog (schemas/mobile-rpc/catalog.json, a0-rpc.md section 4): every
 * message with its family, kind, plane, direction and single owner. The test asserts this equals the
 * JSON file; Swift `MobileCatalog` holds the same table.
 */

export type MobileMessageKind = "op" | "read" | "owner" | "channel" | "message" | "record" | "signal"
export type MobilePlane = "control" | "stream"
export type MobileDirection = "c2s" | "s2c" | "both"

export interface MobileMessageDef {
  readonly name: string
  readonly kind: MobileMessageKind
  readonly plane: MobilePlane
  readonly dir: MobileDirection
  readonly owner: string
  readonly class?: ChannelClass
  readonly existing?: boolean
  readonly errors?: ReadonlyArray<string>
}

export interface MobileFamilyDef {
  readonly name: string
  readonly plane: MobilePlane
  readonly owner: string
  readonly stream?: string
  readonly messages: ReadonlyArray<MobileMessageDef>
}

export const mobileCatalog = {
  proto: "cmux.mobile/1",
  version: 1,
  families: [
    { name: "session", plane: "stream", owner: "mac-host", messages: [
      { name: "rpc", kind: "channel", plane: "stream", dir: "c2s", owner: "mac-host", class: "interactive" },
    ] },
    { name: "host", plane: "control", owner: "HostDO", stream: "host:<host>", messages: [
      { name: "host.list", kind: "read", plane: "control", dir: "c2s", owner: "TeamDO" },
      { name: "host.presence.set", kind: "owner", plane: "control", dir: "s2c", owner: "HostDO" },
      { name: "host.caps.set", kind: "owner", plane: "control", dir: "s2c", owner: "HostDO" },
      { name: "host.wake", kind: "op", plane: "control", dir: "c2s", owner: "HostDO", errors: ["host.not_wakeable"] },
      { name: "host.device.set", kind: "owner", plane: "control", dir: "s2c", owner: "HostDO" },
      { name: "host.device.remove", kind: "owner", plane: "control", dir: "s2c", owner: "HostDO" },
    ] },
    { name: "workspace", plane: "control", owner: "mac-workspace-store", stream: "workspace:<host>", messages: [
      { name: "workspace.upsert", kind: "owner", plane: "control", dir: "s2c", owner: "mac-workspace-store" },
      { name: "workspace.remove", kind: "owner", plane: "control", dir: "s2c", owner: "mac-workspace-store" },
      { name: "workspace.tab.upsert", kind: "owner", plane: "control", dir: "s2c", owner: "mac-workspace-store" },
      { name: "workspace.tab.remove", kind: "owner", plane: "control", dir: "s2c", owner: "mac-workspace-store" },
      { name: "workspace.status.set", kind: "owner", plane: "control", dir: "s2c", owner: "mac-workspace-store" },
      { name: "workspace.preview.set", kind: "owner", plane: "control", dir: "s2c", owner: "mac-workspace-store" },
      { name: "workspace.create", kind: "op", plane: "control", dir: "c2s", owner: "mac-workspace-store" },
      { name: "workspace.rename", kind: "op", plane: "control", dir: "c2s", owner: "mac-workspace-store", errors: ["workspace.not_found"] },
      { name: "workspace.tab.create", kind: "op", plane: "control", dir: "c2s", owner: "mac-workspace-store", errors: ["workspace.not_found"] },
      { name: "workspace.tab.close", kind: "op", plane: "control", dir: "c2s", owner: "mac-workspace-store", errors: ["workspace.tab_not_found"] },
      { name: "workspace.close", kind: "op", plane: "control", dir: "c2s", owner: "mac-workspace-store", errors: ["workspace.not_found"] },
      { name: "workspace.read", kind: "op", plane: "control", dir: "c2s", owner: "mac-workspace-store", errors: ["workspace.not_found"] },
    ] },
    { name: "terminal", plane: "stream", owner: "mac-session-host", messages: [
      { name: "terminal", kind: "channel", plane: "stream", dir: "c2s", owner: "mac-session-host", class: "interactive", errors: ["terminal.not_found", "terminal.exited"] },
      { name: "terminal.output", kind: "record", plane: "stream", dir: "s2c", owner: "mac-session-host" },
      { name: "terminal.input", kind: "record", plane: "stream", dir: "c2s", owner: "mac-session-host" },
      { name: "terminal.viewport", kind: "message", plane: "stream", dir: "c2s", owner: "mac-session-host" },
      { name: "terminal.presence", kind: "message", plane: "stream", dir: "c2s", owner: "mac-session-host" },
      { name: "terminal.snapshot_request", kind: "message", plane: "stream", dir: "c2s", owner: "mac-session-host" },
      { name: "terminal.history", kind: "message", plane: "stream", dir: "c2s", owner: "mac-session-host" },
      { name: "terminal.read_range", kind: "message", plane: "stream", dir: "c2s", owner: "mac-session-host" },
      { name: "terminal.read_range.result", kind: "message", plane: "stream", dir: "s2c", owner: "mac-session-host" },
      { name: "terminal.size", kind: "message", plane: "stream", dir: "s2c", owner: "mac-session-host" },
      { name: "terminal.title", kind: "message", plane: "stream", dir: "s2c", owner: "mac-session-host" },
      { name: "terminal.exited", kind: "message", plane: "stream", dir: "s2c", owner: "mac-session-host" },
      { name: "terminal.kick", kind: "message", plane: "stream", dir: "c2s", owner: "mac-session-host" },
      { name: "terminal.kicked", kind: "message", plane: "stream", dir: "s2c", owner: "mac-session-host" },
    ] },
    { name: "browser", plane: "stream", owner: "mac-browser-host", messages: [
      { name: "browser", kind: "channel", plane: "stream", dir: "c2s", owner: "mac-browser-host", class: "interactive", errors: ["browser.tab_not_found"] },
      { name: "browser.rd", kind: "record", plane: "stream", dir: "both", owner: "mac-browser-host" },
    ] },
    { name: "rd", plane: "stream", owner: "mac-rd-host", messages: [
      { name: "rd", kind: "channel", plane: "stream", dir: "c2s", owner: "mac-rd-host", class: "interactive", errors: ["rd.display_not_found"] },
      { name: "rd.frame", kind: "record", plane: "stream", dir: "both", owner: "mac-rd-host" },
    ] },
    { name: "files", plane: "stream", owner: "mac-host", messages: [
      { name: "files.upload", kind: "channel", plane: "stream", dir: "c2s", owner: "mac-host", class: "bulk", errors: ["files.too_large", "files.dest_invalid"] },
      { name: "files.download", kind: "channel", plane: "stream", dir: "c2s", owner: "mac-host", class: "bulk", errors: ["files.not_found"] },
      { name: "files.chunk", kind: "record", plane: "stream", dir: "both", owner: "mac-host" },
      { name: "files.upload.end", kind: "message", plane: "stream", dir: "c2s", owner: "mac-host" },
      { name: "files.upload.done", kind: "message", plane: "stream", dir: "s2c", owner: "mac-host", errors: ["files.digest_mismatch"] },
      { name: "files.list", kind: "read", plane: "stream", dir: "c2s", owner: "mac-host", errors: ["files.not_found"] },
    ] },
    { name: "feed", plane: "control", owner: "FeedDO", stream: "feed:<user>", messages: [
      { name: "feed.list", kind: "read", plane: "control", dir: "c2s", owner: "FeedDO", existing: true },
      { name: "feed.answer", kind: "op", plane: "control", dir: "c2s", owner: "FeedDO", existing: true },
      { name: "feed.read", kind: "op", plane: "control", dir: "c2s", owner: "FeedDO", existing: true },
      { name: "feed.archive", kind: "op", plane: "control", dir: "c2s", owner: "FeedDO", existing: true },
      { name: "feed.post", kind: "owner", plane: "control", dir: "s2c", owner: "FeedDO", existing: true },
    ] },
    { name: "notify", plane: "control", owner: "UserDO", messages: [
      { name: "push.target.register", kind: "op", plane: "control", dir: "c2s", owner: "UserDO", existing: true },
      { name: "push.target.remove", kind: "op", plane: "control", dir: "c2s", owner: "UserDO", existing: true },
      { name: "push.prefs.set", kind: "op", plane: "control", dir: "c2s", owner: "UserDO", existing: true },
      { name: "notify.activity.register", kind: "op", plane: "control", dir: "c2s", owner: "UserDO", existing: true },
      { name: "notify.activity.end", kind: "op", plane: "control", dir: "c2s", owner: "UserDO", existing: true },
      { name: "notify.badge.set", kind: "owner", plane: "control", dir: "s2c", owner: "UserDO" },
    ] },
    { name: "task", plane: "control", owner: "mac-task-runner", stream: "task:<host>", messages: [
      { name: "task.dispatch", kind: "op", plane: "control", dir: "c2s", owner: "mac-task-runner", errors: ["task.agent_unavailable", "task.attachment_missing"] },
      { name: "task.cancel", kind: "op", plane: "control", dir: "c2s", owner: "mac-task-runner", errors: ["task.not_found"] },
      { name: "task.list", kind: "read", plane: "control", dir: "c2s", owner: "mac-task-runner" },
      { name: "task.state.set", kind: "owner", plane: "control", dir: "s2c", owner: "mac-task-runner" },
    ] },
    { name: "ssh", plane: "control", owner: "UserDO", stream: "ssh:<user>", messages: [
      { name: "ssh.host.upsert", kind: "op", plane: "control", dir: "c2s", owner: "UserDO" },
      { name: "ssh.host.remove", kind: "op", plane: "control", dir: "c2s", owner: "UserDO", errors: ["ssh.host_not_found"] },
      { name: "ssh.known_host.add", kind: "op", plane: "control", dir: "c2s", owner: "UserDO", errors: ["ssh.host_not_found"] },
    ] },
    { name: "pairing", plane: "control", owner: "UserDO", stream: "trust:<user>", messages: [
      { name: "pairing.hosts", kind: "read", plane: "control", dir: "c2s", owner: "UserDO" },
      { name: "trust.key.publish", kind: "op", plane: "control", dir: "c2s", owner: "UserDO", errors: ["trust.bad_signature", "trust.cert_stale"] },
      { name: "pairing.offer", kind: "op", plane: "control", dir: "c2s", owner: "PairingDO", errors: ["pairing.no_host_key"] },
      { name: "pairing.claim", kind: "op", plane: "control", dir: "c2s", owner: "PairingDO", errors: ["pairing.offer_unknown", "pairing.key_mismatch", "pairing.offer_used", "pairing.declined", "pairing.no_device_key"] },
      { name: "trust.request.accept", kind: "op", plane: "control", dir: "c2s", owner: "UserDO", errors: ["pairing.offer_unknown", "pairing.offer_used", "pairing.declined"] },
      { name: "trust.request.decline", kind: "op", plane: "control", dir: "c2s", owner: "UserDO" },
      { name: "pairing.revoke", kind: "op", plane: "control", dir: "c2s", owner: "UserDO", errors: ["selector.not_found"] },
      { name: "trust.key.set", kind: "owner", plane: "control", dir: "s2c", owner: "UserDO" },
      { name: "trust.install.revoked", kind: "owner", plane: "control", dir: "s2c", owner: "UserDO" },
      { name: "trust.request.add", kind: "owner", plane: "control", dir: "s2c", owner: "UserDO" },
      { name: "trust.request.remove", kind: "owner", plane: "control", dir: "s2c", owner: "UserDO" },
      { name: "trust.guest.add", kind: "owner", plane: "control", dir: "s2c", owner: "UserDO" },
      { name: "trust.guest.remove", kind: "owner", plane: "control", dir: "s2c", owner: "UserDO" },
      { name: "trust.remote.add", kind: "owner", plane: "control", dir: "s2c", owner: "UserDO" },
      { name: "trust.remote.remove", kind: "owner", plane: "control", dir: "s2c", owner: "UserDO" },
    ] },
    { name: "signal", plane: "control", owner: "HostDO", messages: [
      { name: "signal.turn_credentials", kind: "read", plane: "control", dir: "c2s", owner: "HostDO", errors: ["signal.turn_unavailable"] },
      { name: "signal.offer", kind: "signal", plane: "control", dir: "both", owner: "HostDO" },
      { name: "signal.answer", kind: "signal", plane: "control", dir: "both", owner: "HostDO" },
      { name: "signal.ice", kind: "signal", plane: "control", dir: "both", owner: "HostDO" },
      { name: "signal.ice.end", kind: "signal", plane: "control", dir: "both", owner: "HostDO" },
      { name: "signal.bye", kind: "signal", plane: "control", dir: "both", owner: "HostDO" },
    ] },
  ]
} as const satisfies { readonly proto: string; readonly version: number; readonly families: ReadonlyArray<MobileFamilyDef> }

export type MobileFamilyName = (typeof mobileCatalog.families)[number]["name"]
export type MobileMessageName = (typeof mobileCatalog.families)[number]["messages"][number]["name"]

/** Message definition by name. */
export const mobileMessageByName: ReadonlyMap<string, MobileMessageDef & { readonly family: MobileFamilyName }> = new Map(
  mobileCatalog.families.flatMap((f) => f.messages.map((m) => [m.name, { ...m, family: f.name }] as const))
)
