declare const resourceIdBrand: unique symbol;
declare const decimalBrand: unique symbol;

export type OpaqueId<Kind extends string> = string & {
  readonly [resourceIdBrand]: Kind;
};

export type MachineId = OpaqueId<"machine">;
export type SessionId = OpaqueId<"session">;
export type WorkspaceId = OpaqueId<"workspace">;
export type ScreenId = OpaqueId<"screen">;
export type PaneId = OpaqueId<"pane">;
export type TabId = OpaqueId<"tab">;
export type TerminalId = OpaqueId<"terminal">;
export type BrowserId = OpaqueId<"browser">;
export type ConnectedClientId = OpaqueId<"connected_client">;
export type SplitId = OpaqueId<"split">;
export type StreamId = OpaqueId<"stream">;
export type NotificationId = OpaqueId<"notification">;
export type AgentId = OpaqueId<"agent">;
export type ProjectionId = OpaqueId<"projection">;
export type PairingRequestId = OpaqueId<"pairing_request">;
export type SidebarViewId = OpaqueId<"sidebar_view">;

/** Exact unsigned decimal wire value, never coerced through Number. */
export type DecimalString = string & { readonly [decimalBrand]: true };

function parseId<Id extends string>(value: string, prefix: string): Id {
  if (!new RegExp(`^${prefix}_[0-9a-f]{32}$`).test(value)) {
    throw new TypeError(
      `expected ${prefix}_ followed by 32 lowercase hexadecimal characters`,
    );
  }
  return value as Id;
}

export const machineId = (value: string): MachineId => parseId(value, "machine");
export const sessionId = (value: string): SessionId => parseId(value, "session");
export const workspaceId = (value: string): WorkspaceId => parseId(value, "ws");
export const screenId = (value: string): ScreenId => parseId(value, "screen");
export const paneId = (value: string): PaneId => parseId(value, "pane");
export const tabId = (value: string): TabId => parseId(value, "tab");
export const terminalId = (value: string): TerminalId => parseId(value, "term");
export const browserId = (value: string): BrowserId => parseId(value, "browser");
export const connectedClientId = (value: string): ConnectedClientId =>
  parseId(value, "client");
export const splitId = (value: string): SplitId => parseId(value, "split");
export const streamId = (value: string): StreamId => parseId(value, "stream");
export const notificationId = (value: string): NotificationId =>
  parseId(value, "notification");
export const agentId = (value: string): AgentId => parseId(value, "agent");
export const projectionId = (value: string): ProjectionId =>
  parseId(value, "projection");
export const pairingRequestId = (value: string): PairingRequestId =>
  parseId(value, "pairing");
export const sidebarViewId = (value: string): SidebarViewId =>
  parseId(value, "sidebar_view");

export function decimalString(value: string): DecimalString {
  if (
    !/^(0|[1-9][0-9]*)$/.test(value)
    || value.length > 20
    || (
      value.length === 20
      && value > "18446744073709551615"
    )
  ) {
    throw new TypeError("expected an unsigned decimal wire string");
  }
  return value as DecimalString;
}

export type Selector<Id extends string> =
  | { readonly kind: "id"; readonly id: Id }
  | { readonly kind: "current" }
  | { readonly kind: "name"; readonly name: string };

export type SelectorInput<Id extends string> = Id | Selector<Id>;

export function selectId<Id extends string>(id: Id): Selector<Id> {
  return Object.freeze({ kind: "id", id });
}

export function selectCurrent<Id extends string>(): Selector<Id> {
  return Object.freeze({ kind: "current" });
}

export function selectName<Id extends string>(name: string): Selector<Id> {
  return Object.freeze({ kind: "name", name });
}

export function encodeSelector<Id extends string>(
  selector: SelectorInput<Id>,
): string {
  if (typeof selector === "string") return selector;
  switch (selector.kind) {
    case "id":
      return selector.id;
    case "current":
      return "current";
    case "name":
      return `name:${selector.name}`;
  }
}
