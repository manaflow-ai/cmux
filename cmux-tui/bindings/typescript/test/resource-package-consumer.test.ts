import assert from "node:assert/strict";
import test from "node:test";

import type {
  Browser,
  BrowserViewerResizeResult,
  CellPixelsResult,
  ConfirmationRequiredDetails,
  ConnectedClient,
  CreationResolution,
  MutationResult,
  PairingRequest,
  PingResult,
  ProcessInfoResult,
  ReloadConfigResult,
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
} from "cmux";

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

test("published resource API exposes catalog-specific result types", () => {
  assert.equal(true, true);
});
