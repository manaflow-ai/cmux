import assert from "node:assert/strict";
import test from "node:test";

import type {
  Agent,
  AgentReportOptions,
  AgentSnapshot,
  Browser,
  BrowserAttachFrame,
  BrowserMouseOptions,
  BrowserViewerResizeResult,
  BrowserWheelOptions,
  CellPixelsResult,
  ConfirmationRequiredDetails,
  ConnectedClient,
  CreatedBrowserPath,
  CreatedPath,
  CreatedTerminalPath,
  CreatedWorkspacePath,
  CreationResolution,
  DecimalString,
  MutationResult,
  NotificationSnapshot,
  Pane,
  PairingRequest,
  PingResult,
  ProcessInfoResult,
  ReloadConfigResult,
  ResourceEntityByKind,
  ResourceIdByKind,
  Screen,
  Session,
  ShutdownResult,
  Terminal,
  TerminalCopyResult,
  TerminalDefaultsSnapshot,
  TerminalHistoryResult,
  TerminalScreenResult,
  TerminalStateResult,
  TerminalWaitExitResult,
  TerminalWaitResult,
  ViewerResizeResult,
  Workspace,
} from "cmux-sdk";

type Equal<Left, Right> =
  (<Value>() => Value extends Left ? 1 : 2) extends
  (<Value>() => Value extends Right ? 1 : 2)
    ? true
    : false;
type Expect<Value extends true> = Value;
type Result<Method extends (...args: never[]) => unknown> =
  Awaited<ReturnType<Method>>;

type _Ping = Expect<Equal<Result<Session["ping"]>, PingResult>>;
type _CreationResolve = Expect<
  Equal<Result<Session["creation"]["resolve"]>, CreationResolution>
>;
type _CreateWorkspace = Expect<
  Equal<
    Result<Session["createWorkspace"]>,
    MutationResult<CreatedPath>
  >
>;
type _WorkspaceCreateScreen = Expect<
  Equal<
    Result<Workspace["createScreen"]>,
    MutationResult<CreatedTerminalPath>
  >
>;
type _WorkspaceRun = Expect<
  Equal<Result<Workspace["run"]>, MutationResult<CreatedTerminalPath>>
>;
type _ScreenCreatePane = Expect<
  Equal<Result<Screen["createPane"]>, MutationResult<CreatedTerminalPath>>
>;
type _PaneCreateTerminal = Expect<
  Equal<
    Result<Pane["createTerminalTab"]>,
    MutationResult<CreatedTerminalPath>
  >
>;
type _PaneCreateBrowser = Expect<
  Equal<
    Result<Pane["createBrowserTab"]>,
    MutationResult<CreatedBrowserPath>
  >
>;
type _PaneSplit = Expect<
  Equal<Result<Pane["split"]>, MutationResult<CreatedTerminalPath>>
>;
type _PaneRun = Expect<
  Equal<Result<Pane["run"]>, MutationResult<CreatedTerminalPath>>
>;
type _BrowserVariant = Expect<
  Equal<
    Extract<CreatedPath, { readonly kind: "browser" }>,
    CreatedBrowserPath
  >
>;
type _TerminalVariant = Expect<
  Equal<
    Extract<CreatedPath, { readonly kind: "terminal" }>,
    CreatedTerminalPath
  >
>;
type _WorkspaceVariant = Expect<
  Equal<
    Extract<CreatedPath, { readonly kind: "workspace" }>,
    CreatedWorkspacePath
  >
>;
type _RequiredBrowser = Expect<
  Equal<CreatedBrowserPath["browser"], Browser>
>;
type _RequiredTerminal = Expect<
  Equal<CreatedTerminalPath["terminal"], Terminal>
>;
type _Shutdown = Expect<
  Equal<Result<Session["shutdown"]>, MutationResult<ShutdownResult>>
>;
type _Reload = Expect<
  Equal<Result<Session["reloadConfig"]>, MutationResult<ReloadConfigResult>>
>;
type _Defaults = Expect<
  Equal<
    Result<Session["updateTerminalDefaults"]>,
    MutationResult<TerminalDefaultsSnapshot>
  >
>;
type _ReportAgent = Expect<
  Equal<Result<Session["reportAgent"]>, MutationResult<Agent>>
>;
type _ReportAgentOptions = Expect<
  Equal<Parameters<Session["reportAgent"]>[0], AgentReportOptions>
>;
type _AgentHasNoReport = Expect<
  Equal<"report" extends keyof Agent ? true : false, false>
>;
type _Screen = Expect<
  Equal<Result<Terminal["readScreen"]>, TerminalScreenResult>
>;
type _State = Expect<
  Equal<Result<Terminal["readState"]>, TerminalStateResult>
>;
type _History = Expect<
  Equal<Result<Terminal["readHistory"]>, TerminalHistoryResult>
>;
type _Wait = Expect<
  Equal<Result<Terminal["wait"]>, TerminalWaitResult>
>;
type _WaitExit = Expect<
  Equal<Result<Terminal["waitExit"]>, TerminalWaitExitResult>
>;
type _Copy = Expect<
  Equal<Result<Terminal["copy"]>, TerminalCopyResult>
>;
type _Process = Expect<
  Equal<Result<Terminal["process"]>, ProcessInfoResult>
>;
type _TerminalResize = Expect<
  Equal<Result<Terminal["resizeViewer"]>, ViewerResizeResult>
>;
type _BrowserResize = Expect<
  Equal<Result<Browser["resizeViewer"]>, BrowserViewerResizeResult>
>;
type _BrowserFramePointer = Expect<
  Equal<BrowserAttachFrame["pointerFrameSeq"], DecimalString | null>
>;
type _BrowserMousePointer = Expect<
  Equal<BrowserMouseOptions["pointerFrameSeq"], DecimalString>
>;
type _BrowserWheelPointer = Expect<
  Equal<BrowserWheelOptions["pointerFrameSeq"], DecimalString>
>;
type _BrowserWheelInput = Expect<
  Equal<Parameters<Browser["wheel"]>[0], BrowserWheelOptions>
>;
type _CellPixels = Expect<
  Equal<Result<ConnectedClient["setCellPixels"]>, CellPixelsResult>
>;
type _Pairing = Expect<
  Equal<
    Result<PairingRequest["resolve"]>,
    MutationResult<PairingRequest>
  >
>;
type _ConfirmationToken = Expect<
  Equal<ConfirmationRequiredDetails["confirmation_token"], string>
>;

function compileNarrowCreatedPath(path: CreatedPath): void {
  if (path.kind === "browser") {
    const browser: Browser = path.browser;
    void browser;
    // @ts-expect-error Browser paths cannot expose a terminal.
    void path.terminal;
  } else if (path.kind === "terminal") {
    const terminal: Terminal = path.terminal;
    void terminal;
    // @ts-expect-error Terminal paths cannot expose a browser.
    void path.browser;
  } else {
    const workspace: Workspace = path.workspace;
    void workspace;
    // @ts-expect-error Workspace-only paths cannot expose nested handles.
    void path.screen;
  }
}

function compileAuxiliaryResourceMapping(
  agent: AgentSnapshot,
  notification: NotificationSnapshot,
): void {
  const notificationValue: ResourceEntityByKind["notification"] = notification;
  const notificationId: ResourceIdByKind["notification"] = notification.id;
  void notificationValue;
  void notificationId;

  // @ts-expect-error A notification discriminant cannot select an agent result.
  const wrongValue: ResourceEntityByKind["notification"] = agent;
  // @ts-expect-error A notification discriminant cannot select an agent ID.
  const wrongId: ResourceIdByKind["notification"] = agent.id;
  void wrongValue;
  void wrongId;
}

function compileBrowserPointerInput(
  browser: Browser,
  pointerFrameSeq: DecimalString,
): void {
  void browser.mouse({
    kind: "move",
    xPx: 10,
    yPx: 20,
    pointerFrameSeq,
  });
  void browser.wheel({
    deltaX: 0,
    deltaY: -120,
    xPx: 10,
    yPx: 20,
    pointerFrameSeq,
  });
  // @ts-expect-error Pointer input cannot omit the exact presented frame token.
  void browser.mouse({ kind: "move", xPx: 10, yPx: 20 });
  void browser.wheel({
    deltaX: 0,
    deltaY: -120,
    xPx: 10,
    yPx: 20,
    // @ts-expect-error Pointer input cannot use a nullable frame token.
    pointerFrameSeq: null,
  });
}

test("published resource API exposes catalog-specific result types", () => {
  void compileNarrowCreatedPath;
  void compileAuxiliaryResourceMapping;
  void compileBrowserPointerInput;
  assert.equal(true, true);
});
